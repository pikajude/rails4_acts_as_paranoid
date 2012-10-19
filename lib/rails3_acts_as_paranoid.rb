require 'active_record'
require 'validations/uniqueness_without_deleted'


module ActiveRecord
  class Relation
    def paranoid?
      klass.try(:paranoid?) ? true : false
    end

    def paranoid_deletion_attributes
      { klass.paranoid_column => klass.delete_now_value }
    end

    alias_method :destroy!, :destroy
    def destroy(id)
      if paranoid?
        update_all(paranoid_deletion_attributes, {:id => id})
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
      wd = self.clone
      wd.default_scoped = false
      wd.arel = self.build_arel
      wd
    end
  end
end

module ActsAsParanoid

  def paranoid?
    self.included_modules.include?(InstanceMethods)
  end

  def validates_as_paranoid
    extend ParanoidValidations::ClassMethods
  end

  # TODO: Make private
  def primary_deleted_column(options={})
    return {} unless options[:columns]
    column = options[:columns].detect do |column_config|
        column_config[:column] == options[:primary_deleted_column]
    end
    column || options[:columns].first
  end

  # TODO: Make private
  def secondary_deleted_columns(options={})
    return [] unless options[:columns]
    primary_deleted_column_name = primary_deleted_column(options)[:column]
    options[:columns].reject { |column_config| column_config[:column] == options[:primary_deleted_column] }
  end

  # TODO: Make private
  def default_primary_deleted_column
    {
      :column                         => "deleted_at",
      :column_type                    => "time",
      :recover_dependent_associations => true,
      :dependent_recovery_window      => 2.minutes,
      :deleted_value                  => "deleted"
    }
  end

  def primary_column(options)
    default_primary_deleted_column.merge(options.merge(primary_deleted_column(options)))
  end

  def column_reference(column)
    "#{self.table_name}.#{column}"
  end

  def paranoid_column_reference
    column_reference configuration[:primary_deleted_column][:column]
  end

  def validate_paranoid_columns!
    unless ['time', 'boolean', 'string'].include? configuration[:primary_deleted_column][:column_type]
      raise ArgumentError, "'time', 'boolean' or 'string' expected for :column_type option, got #{configuration[:primary_deleted_column][:column_type]}"
    end
  end

  def acts_as_paranoid(options = {})
    raise ArgumentError, "Hash expected, got #{options.class.name}" if not options.is_a?(Hash) and not options.empty?

    # TODO: rename configuration to something more paranoid specific
    class_attribute :paranoid_configuration, :configuration

    self.configuration = {
      :primary_deleted_column    => primary_column(options),
      :secondary_deleted_columns => secondary_deleted_columns(options)
    }

    validate_paranoid_columns!

    return if paranoid?

    # Magic!
    default_scope { where("#{paranoid_column_reference} IS ?", nil) }

    scope :paranoid_deleted_around_time, lambda {|value, window|
      if self.class.respond_to?(:paranoid?) && self.class.paranoid?
        if self.class.paranoid_column_type == 'time' && ![true, false].include?(value)
          self.where("#{self.class.paranoid_column} > ? AND #{self.class.paranoid_column} < ?", (value - window), (value + window))
        else
          self.only_deleted
        end
      end if configuration[:primary_deleted_column][:column_type] == 'time'
    }

    include InstanceMethods
    extend ClassMethods
  end

  module ClassMethods
    def self.extended(base)
      base.define_callbacks :recover
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
      self.unscoped.where("#{paranoid_column_reference} IS NOT ?", nil)
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
      columns = configuration[:secondary_deleted_columns].push(configuration[:primary_deleted_column])
      update_string = columns.map{ |column| "#{column[:column]} = ?" }.join(", ")
      update_values = columns.map{ |column| delete_now_value column }
      update_all [update_string, *update_values], conditions
    end

    def paranoid_column
      configuration[:primary_deleted_column][:column].to_sym
    end

    def paranoid_column_type
      configuration[:primary_deleted_column][:column_type].to_sym
    end

    def dependent_associations
      self.reflect_on_all_associations.select {|a| [:destroy, :delete_all].include?(a.options[:dependent]) }
    end

    def delete_now_value(column=nil)
      column ||= configuration[:primary_deleted_column]
      case column[:column_type]
        when "time" then Time.now
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
      with_transaction_returning_status do
        run_callbacks :destroy do
          act_on_dependent_destroy_associations
          self.class.delete_all!(self.class.primary_key.to_sym => self.id)
          self.paranoid_value = self.class.delete_now_value
          freeze
        end
      end
    end

    def destroy
      if paranoid_value.nil?
        with_transaction_returning_status do
          run_callbacks :destroy do
            self.class.delete_all(self.class.primary_key.to_sym => self.id)
            self.paranoid_value = self.class.delete_now_value
            self
          end
        end
      else
        destroy!
      end
    end

    def delete!
      with_transaction_returning_status do
        act_on_dependent_destroy_associations
        self.class.delete_all!(self.class.primary_key.to_sym => self.id)
        self.paranoid_value = self.class.delete_now_value
        freeze
      end
    end

    def delete
      if paranoid_value.nil?
        with_transaction_returning_status do
          self.class.delete_all(self.class.primary_key.to_sym => self.id)
          self.paranoid_value = self.class.delete_now_value
          self
        end
      else
        delete!
      end
    end

    def recover(options={})
      options = {
                  :recursive => self.class.configuration[:primary_deleted_column][:recover_dependent_associations],
                  :recovery_window => self.class.configuration[:primary_deleted_column][:dependent_recovery_window]
                }.merge(options)

      self.class.transaction do
        run_callbacks :recover do
          recover_dependent_associations(options[:recovery_window], options) if options[:recursive]

          self.paranoid_value = nil
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
          association.klass.with_deleted.instance_eval("find_all_by_#{association.foreign_key}(#{self.id.to_json})").each do |object|
            object.destroy!
          end
        end
      end
    end

    def deleted?
      !paranoid_value.nil?
    end
    alias_method :destroyed?, :deleted?

  private
    def paranoid_value=(value)
      self.send("#{self.class.paranoid_column}=", value)
    end

  end
end


# Extend ActiveRecord's functionality
ActiveRecord::Base.send :extend, ActsAsParanoid

# Push the recover callback onto the activerecord callback list
ActiveRecord::Callbacks::CALLBACKS.push(:before_recover, :after_recover)
