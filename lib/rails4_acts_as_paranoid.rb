require 'active_record'
require 'validations/uniqueness_without_deleted'

module ActiveRecord
  class Relation
    VALUES = [
      :bind_values,
      :create_with_value,
      :eager_load_values,
      :from_value,
      :group_values,
      :having_values,
      :includes_values,
      :joins_values,
      :limit_value,
      :lock_value,
      :offset_value,
      :order_values,
      :preload_values,
      :readonly_value,
      :reordering_value,
      :reverse_order_value,
      :select_values,
      :uniq_value,
      :where_values
    ]

    def paranoid?
      klass.try(:paranoid?) ? true : false
    end

    def paranoid_deletion_attributes
      { klass.paranoid_column => klass.delete_now_value }
    end

    alias_method :destroy!, :destroy
    def destroy(id)
      if paranoid?
        where(id: id).update_all(paranoid_deletion_attributes)
      else
        destroy!(id)
      end
    end

    alias_method :really_delete_all!, :delete_all

    def delete_all!(conditions = nil)
      if conditions
        # This idea comes out of Rails 3.1 ActiveRecord::Record.delete_all
        where(conditions).delete_all!
      else
        really_delete_all!
      end
    end

    def delete_all(conditions = nil)
      if paranoid?
        update_all(paranoid_deletion_attributes, conditions)
      else
        delete_all!(conditions)
      end
    end

    def arel=(a)
      @arel = a
    end

    def with_deleted
      wd = self.clone.unscoped
      VALUES.each do |v|
        if self.respond_to?(v) && wd.respond_to?("#{v}=")
          wd.send("#{v}=", self.send(v))
        end
      end
      wd
    end
  end
end

module ActsAsParanoid
  DEFAULT_CONFIG = {
    :column                         => "deleted_at",
    :column_type                    => "time",
    :recover_dependent_associations => true,
    :dependent_recovery_window      => 2.minutes
  }

  def self.default_config=(config={})
    DEFAULT_CONFIG.merge! config
  end

  def paranoid?
    self.included_modules.include?(InstanceMethods)
  end

  def is_not_paranoid_deleted
    operator = non_deleted_value.nil? ? "IS" : "="
    ["#{paranoid_column_reference} #{operator} ?", non_deleted_value]
  end

  def is_paranoid_deleted
    operator = non_deleted_value.nil? ? "IS NOT" : "!="
    ["#{paranoid_column_reference} #{operator} ?", non_deleted_value]
  end

  def non_deleted_value
    primary_paranoid_column[:column_type] == "boolean" ? false : nil
  end

  def validates_as_paranoid
    extend ParanoidValidations::ClassMethods
  end

  def primary_paranoid_column
    self.paranoid_configuration[:primary_column]
  end

  def secondary_paranoid_columns
    self.paranoid_configuration[:secondary_columns]
  end

  def build_column_config(options={})
    column = DEFAULT_CONFIG.dup
    column.delete(:columns)
    column = column.merge(:deleted_value => "deleted") if options[:column_type] == "string"
    column = column.merge(options)

    unless ['time', 'boolean', 'string'].include? column[:column_type]
      raise ArgumentError, "'time', 'boolean' or 'string' expected for :column_type option, got #{column[:column_type]}"
    end

    column
  end

  def acts_as_paranoid(options = {})
    raise ArgumentError, "Hash expected, got #{options.class.name}" if not options.is_a?(Hash) and not options.empty?

    class_attribute :paranoid_configuration, :paranoid_column_reference

    options = DEFAULT_CONFIG.merge(options)
    if options[:columns]
      primary_column    = options[:columns].first
      secondary_columns = options[:columns][1..-1]
    else
      primary_column    = options
      secondary_columns = []
    end
    self.paranoid_configuration = {
      :primary_column    => build_column_config(primary_column),
      :secondary_columns => secondary_columns.map { |column| build_column_config(column) }
    }

    self.paranoid_column_reference = "#{self.table_name}.#{primary_paranoid_column[:column]}"

    return if paranoid?

    # Magic!
    default_scope { where(*is_not_paranoid_deleted) }

    scope :paranoid_deleted_around_time, lambda {|value, window|
      if self.class.respond_to?(:paranoid?) && self.class.paranoid?
        if self.class.paranoid_column_type == 'time' && ![true, false].include?(value)
          self.where("#{self.class.paranoid_column} > ? AND #{self.class.paranoid_column} < ?", (value - window), (value + window))
        else
          self.only_deleted
        end
      end if primary_paranoid_column[:column_type] == 'time'
    }

    include InstanceMethods
    extend ClassMethods
  end

  module ClassMethods
    def self.extended(base)
      base.define_callbacks :recover
      base.skip_time_zone_conversion_for_attributes = [base.paranoid_column, :created_at, :updated_at]
    end

    def before_recover(method)
      set_callback :recover, :before, method
    end

    def after_recover(method)
      set_callback :recover, :after, method
    end

    def with_deleted
      self.unscoped
    end

    def only_deleted
      self.unscoped.where(*is_paranoid_deleted)
    end

    def deletion_conditions(id_or_array)
      ["id in (?)", [id_or_array].flatten]
    end

    def delete!(id_or_array)
      delete_all!(deletion_conditions(id_or_array))
    end

    def delete(id_or_array)
      delete_all(deletion_conditions(id_or_array))
    end

    def delete_all!(conditions = nil)
      self.unscoped.delete_all!(conditions)
    end

    def delete_all(conditions = nil)
      columns = secondary_paranoid_columns.clone.push(primary_paranoid_column)

      sql = columns.map do |column|
        "#{column[:column]} = ?"
      end.join(", ")
      values = columns.map{ |column| delete_now_value(column) }

      where(conditions).update_all [sql, *values]
    end

    def paranoid_column
      primary_paranoid_column[:column].to_sym
    end

    def paranoid_column_type
      primary_paranoid_column[:column_type].to_sym
    end

    def dependent_associations
      self.reflect_on_all_associations.select {|a| [:destroy, :delete_all].include?(a.options[:dependent]) }
    end

    def delete_now_value(column=nil)
      column ||= primary_paranoid_column
      case column[:column_type]
        when "time" then Time.now.utc
        when "boolean" then true
        when "string" then column[:deleted_value]
      end
    end
  end

  module InstanceMethods

    def paranoid_value
      self.send(self.class.paranoid_column)
    end

    def destroy!
      return self unless check_persisted_for_delete(true)
      with_transaction_returning_status do
        run_callbacks :destroy do
          act_on_dependent_destroy_associations
          self.class.delete_all!(self.class.primary_key.to_sym => self.id)
          set_paranoid_value true
        end
      end
    end

    def destroy
      return self unless check_persisted_for_delete(false)
      if !deleted?
        with_transaction_returning_status do
          run_callbacks :destroy do
            self.class.delete_all(self.class.primary_key.to_sym => self.id)
            set_paranoid_value false
          end
        end
      else
        destroy!
      end
    end

    def delete!
      return self unless check_persisted_for_delete(true)
      with_transaction_returning_status do
        act_on_dependent_destroy_associations
        self.class.delete_all!(self.class.primary_key.to_sym => self.id)
        set_paranoid_value true
      end
    end

    def delete
      return self unless check_persisted_for_delete(false)
      if !deleted?
        with_transaction_returning_status do
          self.class.delete_all(self.class.primary_key.to_sym => self.id)
          set_paranoid_value false
        end
      else
        delete!
      end
    end

    def recover(options={})
      options = {
                  :recursive => self.class.primary_paranoid_column[:recover_dependent_associations],
                  :recovery_window => self.class.primary_paranoid_column[:dependent_recovery_window]
                }.merge(options)

      self.class.transaction do
        run_callbacks :recover do
          recover_dependent_associations(options[:recovery_window], options) if options[:recursive]

          self.paranoid_value = self.class.non_deleted_value
          self.save
        end
      end
    end

    def recover_dependent_associations(window, options)
      self.class.dependent_associations.each do |association|
        if association.collection? && self.send(association.name).paranoid?
          self.send(association.name).unscoped do
            self.send(association.name).paranoid_deleted_around_time(paranoid_value, window).each do |object|
              object.recover(options) if object.respond_to?(:recover)
            end
          end
        elsif association.macro == :has_one && association.klass.paranoid?
          association.klass.unscoped do
            object = association.klass.paranoid_deleted_around_time(paranoid_value, window).send('find_by_'+association.foreign_key, self.id)
            object.recover(options) if object && object.respond_to?(:recover)
          end
        elsif association.klass.paranoid?
          association.klass.unscoped do
            id = self.send(association.foreign_key)
            object = association.klass.paranoid_deleted_around_time(paranoid_value, window).find_by_id(id)
            object.recover(options) if object && object.respond_to?(:recover)
          end
        end
      end
    end

    def act_on_dependent_destroy_associations
      self.class.dependent_associations.each do |association|
        if association.collection? && self.send(association.name).paranoid?
          association.klass.with_deleted.where(association.foreign_key.to_sym => self.id.to_json).each do |object|
            object.destroy!
          end
        end
      end
    end

    def deleted?
      !(paranoid_value == self.class.non_deleted_value)
    end
    alias_method :destroyed?, :deleted?

  private
    def paranoid_value=(value)
      self.send("#{self.class.paranoid_column}=", value)
    end

    def check_persisted_for_delete(permanent)
      if !self.id
        set_paranoid_value permanent
        return false
      end
      true
    end

    def set_paranoid_value(permanent)
      self.paranoid_value = self.class.delete_now_value
      freeze if permanent
      self
    end
  end

end


# Extend ActiveRecord's functionality
ActiveRecord::Base.send :extend, ActsAsParanoid

# Push the recover callback onto the activerecord callback list
ActiveRecord::Callbacks::CALLBACKS.push(:before_recover, :after_recover)
