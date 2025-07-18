module ActiveRecord
  module Acts #:nodoc:
    module List #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end

      # This +acts_as+ extension provides the capabilities for sorting and reordering a number of objects in a list.
      # The class that has this specified needs to have a +position+ column defined as an integer on
      # the mapped database table.
      #
      # Todo list example:
      #
      #   class TodoList < ActiveRecord::Base
      #     has_many :todo_items, :order => "position"
      #   end
      #
      #   class TodoItem < ActiveRecord::Base
      #     belongs_to :todo_list
      #     acts_as_list :scope => :todo_list
      #   end
      #
      #   todo_list.first.move_to_bottom
      #   todo_list.last.move_higher
      module ClassMethods
        # Rails 7 removed +sanitize_sql_hash_for_conditions+, so we provide a
        # replacement that works across modern versions.
        def sanitize_sql_hash_for_conditions(attrs)
          table = connection.quote_table_name(table_name)
          attrs.map do |attr, value|
            if respond_to?(:type_for_attribute)
              type  = type_for_attribute(attr.to_s)
              value = type.serialize(type.cast(value))
            end
            col = connection.quote_column_name(attr)
            if value.nil?
              "#{table}.#{col} IS NULL"
            else
              "#{table}.#{col} = #{connection.quote(value)}"
            end
          end.join(' AND ')
        end unless method_defined?(:sanitize_sql_hash_for_conditions)

        # Configuration options are:
        #
        # * +column+ - specifies the column name to use for keeping the position integer (default: +position+)
        # * +scope+ - restricts what is to be considered a list. Given a symbol, it'll attach <tt>_id</tt> 
        #   (if it hasn't already been added) and use that as the foreign key restriction. It's also possible 
        #   to give it an entire string that is interpolated if you need a tighter scope than just a foreign key.
        #   Example: <tt>acts_as_list :scope => 'todo_list_id = #{todo_list_id} AND completed = 0'</tt>
        def acts_as_list(options = {})
          configuration = { :column => "position", :scope => "1 = 1", :bulk_reorder => false }
          configuration.update(options) if options.is_a?(Hash)

          configuration[:scope] = "#{configuration[:scope]}_id".intern if configuration[:scope].is_a?(Symbol) && configuration[:scope].to_s !~ /_id$/

          if configuration[:scope].is_a?(Symbol)
            scope_key = configuration[:scope].to_sym.inspect
            scope_condition_method = <<-RUBY
              def scope_condition
                self.class.send(:sanitize_sql_hash_for_conditions, { #{scope_key} => send(#{scope_key}) })
              end
            RUBY
          elsif configuration[:scope].is_a?(Array)
            scope_columns = configuration[:scope].map { |c| c.to_sym.inspect }.join(', ')
            scope_condition_method = <<-RUBY
              def scope_condition
                attrs = [#{scope_columns}].inject({}) do |memo, column|
                  memo[column] = send(column); memo
                end
                self.class.send(:sanitize_sql_hash_for_conditions, attrs)
              end
            RUBY
          else
            scope_string = configuration[:scope].to_s
            scope_string = scope_string.gsub(/\\/, '\\\\').gsub(/"/, '\\"')
            scope_condition_method = "def scope_condition() \"#{scope_string}\" end"
          end

          class_eval <<-EOV
            include ActiveRecord::Acts::List::InstanceMethods

            cattr_accessor :acts_as_list_options

            def acts_as_list_class
              ::#{self.name}
            end

            def position_column
              #{configuration[:column].to_s.inspect}
            end

            #{scope_condition_method}

            before_destroy :decrement_positions_on_lower_items
            before_create  :add_to_list_bottom
            before_update  :acts_as_list_handle_scope_change
            after_update   :acts_as_list_restore_position
          EOV
          self.acts_as_list_options = configuration
        end

        def reorder_list(ids)
          raise ArgumentError, 'Bulk reorder disabled' unless acts_as_list_options[:bulk_reorder]
          ids = Array(ids).map(&:to_i)
          return if ids.empty?

          records = where(primary_key => ids).to_a
          return if records.empty?
          scope_sql = records.first.scope_condition
          raise ArgumentError, 'All records must be in the same scope' unless records.all? { |r| r.scope_condition == scope_sql }

          case_statements = ids.each_with_index.map { |id, index| "WHEN #{id} THEN #{index + 1}" }.join(' ')
          update_sql = "#{connection.quote_column_name(acts_as_list_options[:column])} = CASE #{connection.quote_column_name(primary_key)} #{case_statements} END"

          transaction do
            where(scope_sql).where(primary_key => ids).update_all(update_sql)
          end
        end
      end

      # All the methods available to a record that has had <tt>acts_as_list</tt> specified. Each method works
      # by assuming the object to be the item in the list, so <tt>chapter.move_lower</tt> would move that chapter
      # lower in the list of all chapters. Likewise, <tt>chapter.first?</tt> would return +true+ if that chapter is
      # the first in the list of all chapters.
      module InstanceMethods
        # Insert the item at the given position (defaults to the top position of 1).
        def insert_at(position = 1)
          insert_at_position(position)
        end

        # Swap positions with the next lower item, if one exists.
        def move_lower
          return unless lower_item

          acts_as_list_class.transaction do
            lower_item.decrement_position
            increment_position
          end
        end

        # Swap positions with the next higher item, if one exists.
        def move_higher
          return unless higher_item

          acts_as_list_class.transaction do
            higher_item.increment_position
            decrement_position
          end
        end

        # Move to the bottom of the list. If the item is already in the list, the items below it have their
        # position adjusted accordingly.
        def move_to_bottom
          return unless in_list?
          acts_as_list_class.transaction do
            decrement_positions_on_lower_items
            assume_bottom_position
          end
        end

        # Move to the top of the list. If the item is already in the list, the items above it have their
        # position adjusted accordingly.
        def move_to_top
          return unless in_list?
          acts_as_list_class.transaction do
            increment_positions_on_higher_items
            assume_top_position
          end
        end

        # Move this item so it is immediately above +item+ in the list.
        def move_above(item)
          return unless item
          insert_at(item.send(position_column) -
                    (in_list? && self.send(position_column).to_i < item.send(position_column).to_i ? 1 : 0))
        end

        # Move this item so it is immediately below +item+ in the list.
        def move_below(item)
          return unless item
          insert_at(item.send(position_column) +
                    (in_list? && self.send(position_column).to_i > item.send(position_column).to_i ? 1 : 0))
        end

        # Swap this item's position with +item+ while maintaining list integrity.
        def swap_positions_with(item)
          return unless item && in_list? && item.in_list?
          raise ArgumentError, 'You can only swap with an item in the same scope.' unless scope_condition == item.scope_condition

          acts_as_list_class.transaction do
            other_position = item.send(position_column)
            item.update_attribute(position_column, send(position_column))
            update_attribute(position_column, other_position)
          end
        end

        # Removes the item from the list.
        def remove_from_list
          if in_list?
            decrement_positions_on_lower_items
            update_attribute position_column, nil
          end
        end

        # Increase the position of this item without adjusting the rest of the list.
        def increment_position
          return unless in_list?
          update_attribute position_column, self.send(position_column).to_i + 1
        end

        # Decrease the position of this item without adjusting the rest of the list.
        def decrement_position
          return unless in_list?
          update_attribute position_column, self.send(position_column).to_i - 1
        end

        # Return +true+ if this object is the first in the list.
        def first?
          return false unless in_list?
          self.send(position_column) == 1
        end

        # Return +true+ if this object is the last in the list.
        def last?
          return false unless in_list?
          self.send(position_column) == bottom_position_in_list
        end

        # Return the next higher item in the list.
        def higher_item
          return nil unless in_list?
          acts_as_list_class.where(
            ["#{scope_condition} AND #{position_column} = ?", send(position_column).to_i - 1]
          ).first
        end

        # Return the next lower item in the list.
        def lower_item
          return nil unless in_list?
          acts_as_list_class.where(
            ["#{scope_condition} AND #{position_column} = ?", send(position_column).to_i + 1]
          ).first
        end

        # Test if this record is in a list
        def in_list?
          !send(position_column).nil?
        end

        private
          def add_to_list_top
            increment_positions_on_all_items
          end

          def add_to_list_bottom
            self[position_column] = bottom_position_in_list.to_i + 1
          end

          # Overwrite this method to define the scope of the list changes
          def scope_condition() "1" end

          # Returns the bottom position number in the list.
          #   bottom_position_in_list    # => 2
          def bottom_position_in_list(except = nil)
            item = bottom_item(except)
            item ? item.send(position_column) : 0
          end

          # Returns the bottom item
          def bottom_item(except = nil)
            conditions = scope_condition
            if except
              acts_as_list_class.where(["#{conditions} AND #{self.class.primary_key} != ?", except.id]).order("#{position_column} DESC").first
            else
              acts_as_list_class.where(conditions).order("#{position_column} DESC").first
            end
          end

          # Forces item to assume the bottom position in the list.
          def assume_bottom_position
            update_attribute(position_column, bottom_position_in_list(self).to_i + 1)
          end

          # Forces item to assume the top position in the list.
          def assume_top_position
            update_attribute(position_column, 1)
          end

          # This has the effect of moving all the higher items up one.
          def decrement_positions_on_higher_items(position)
            acts_as_list_class.where(
              ["#{scope_condition} AND #{position_column} <= ?", position]
            ).update_all("#{position_column} = (#{position_column} - 1)")
          end

          # This has the effect of moving all the lower items up one.
          def decrement_positions_on_lower_items
            return unless in_list?
            acts_as_list_class.where(
              ["#{scope_condition} AND #{position_column} > ?", send(position_column).to_i]
            ).update_all("#{position_column} = (#{position_column} - 1)")
          end

          # This has the effect of moving all the higher items down one.
          def increment_positions_on_higher_items
            return unless in_list?
            acts_as_list_class.where(
              ["#{scope_condition} AND #{position_column} < ?", send(position_column).to_i]
            ).update_all("#{position_column} = (#{position_column} + 1)")
          end

          # This has the effect of moving all the lower items down one.
          def increment_positions_on_lower_items(position)
            acts_as_list_class.where(
              ["#{scope_condition} AND #{position_column} >= ?", position]
           ).update_all("#{position_column} = (#{position_column} + 1)")
          end

          # Increments position (<tt>position_column</tt>) of all items in the list.
        def increment_positions_on_all_items
          acts_as_list_class.where(
            scope_condition
          ).update_all("#{position_column} = (#{position_column} + 1)")
        end

        def acts_as_list_handle_scope_change
          return unless acts_as_list_scope_changed?

          old_scope = acts_as_list_old_scope_condition
          old_position = send("#{position_column}_was")
          if old_position
            acts_as_list_class.where([
              "#{old_scope} AND #{position_column} > ?", old_position.to_i
            ]).update_all("#{position_column} = (#{position_column} - 1)")
          end
          self[position_column] = nil
          @__aal_scope_changed = true
        end

        def acts_as_list_restore_position
          return unless @__aal_scope_changed
          update_column(position_column, bottom_position_in_list.to_i + 1)
        end

        def acts_as_list_scope_changed?
          scope = acts_as_list_class.acts_as_list_options[:scope]
          case scope
          when Symbol
            attribute_changed?(scope)
          when Array
            scope.any? { |attr| attribute_changed?(attr) }
          else
            false
          end
        end

        def acts_as_list_old_scope_condition
          scope = acts_as_list_class.acts_as_list_options[:scope]
          case scope
          when Symbol
            val = send("#{scope}_was")
            self.class.send(:sanitize_sql_hash_for_conditions, { scope => val })
          when Array
            attrs = scope.each_with_object({}) { |a, memo| memo[a] = send("#{a}_was") }
            self.class.send(:sanitize_sql_hash_for_conditions, attrs)
          else
            scope_condition
          end
        end

        def attribute_changed?(attr)
          if respond_to?("will_save_change_to_#{attr}?")
            send("will_save_change_to_#{attr}?")
          elsif respond_to?("#{attr}_changed?")
            send("#{attr}_changed?")
          else
            false
          end
        end

          def insert_at_position(position)
            remove_from_list
            increment_positions_on_lower_items(position)
            self.update_attribute(position_column, position)
          end
      end 
    end
  end
end
