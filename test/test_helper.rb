require 'rubygems'
require 'test/unit'
require 'active_support'
require 'active_support/core_ext/numeric/time'
require 'active_record'
require 'rails/observers/activerecord/active_record'
require 'active_model'

$:.unshift "#{File.dirname(__FILE__)}/../"
$:.unshift "#{File.dirname(__FILE__)}/../lib/"
$:.unshift "#{File.dirname(__FILE__)}/../lib/validations"

require 'init'

ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :database => ":memory:")
ActiveRecord::Migration.verbose = false

def setup_db
  ActiveRecord::Schema.define(:version => 1) do
    create_table :paranoid_times do |t|
      t.string    :name
      t.datetime  :deleted_at
      t.integer   :paranoid_belongs_dependant_id
      t.integer   :not_paranoid_id

      t.timestamps
    end

    create_table :paranoid_booleans do |t|
      t.string    :name
      t.boolean   :is_deleted, :default => false
      t.integer   :paranoid_time_id

      t.timestamps
    end

    create_table :paranoid_boolean_and_dates do |t|
      t.string    :name
      t.datetime  :deleted_at
      t.boolean   :is_deleted, :default => false
      t.integer   :paranoid_time_id

      t.timestamps
    end

    create_table :paranoid_strings do |t|
      t.string    :name
      t.string    :deleted
    end

    create_table :not_paranoids do |t|
      t.string    :name
      t.integer   :paranoid_time_id

      t.timestamps
    end

    create_table :has_one_not_paranoids do |t|
      t.string    :name
      t.integer   :paranoid_time_id

      t.timestamps
    end

    create_table :paranoid_has_many_dependants do |t|
      t.string    :name
      t.datetime  :deleted_at
      t.integer   :paranoid_time_id
      t.integer   :paranoid_belongs_dependant_id

      t.timestamps
    end

    create_table :paranoid_belongs_dependants do |t|
      t.string    :name
      t.datetime  :deleted_at

      t.timestamps
    end

    create_table :paranoid_has_one_dependants do |t|
      t.string    :name
      t.datetime  :deleted_at
      t.integer   :paranoid_boolean_id

      t.timestamps
    end

    create_table :paranoid_with_callbacks do |t|
      t.string    :name
      t.datetime  :deleted_at

      t.timestamps
    end

    create_table :paranoid_destroy_companies do |t|
      t.string :name
      t.datetime :deleted_at

      t.timestamps
    end

    create_table :paranoid_delete_companies do |t|
      t.string :name
      t.datetime :deleted_at

      t.timestamps
    end

    create_table :paranoid_products do |t|
      t.integer :paranoid_destroy_company_id
      t.integer :paranoid_delete_company_id
      t.string :name
      t.datetime :deleted_at

      t.timestamps
    end

    create_table :super_paranoids do |t|
      t.string :type
      t.references :has_many_inherited_super_paranoidz
      t.datetime :deleted_at

      t.timestamps
    end

    create_table :has_many_inherited_super_paranoidzs do |t|
      t.references :super_paranoidz
      t.datetime :deleted_at

      t.timestamps
    end

    create_table :paranoid_many_many_parent_lefts do |t|
      t.string :name
      t.timestamps
    end

    create_table :paranoid_many_many_parent_rights do |t|
      t.string :name
      t.timestamps
    end

    create_table :paranoid_many_many_children do |t|
      t.integer :paranoid_many_many_parent_left_id
      t.integer :paranoid_many_many_parent_right_id
      t.datetime :deleted_at
      t.timestamps
    end

    create_table :paranoid_with_scoped_validations do |t|
      t.string :name
      t.string :category
      t.datetime :deleted_at
      t.timestamps
    end

  end
end

def teardown_db
  ActiveRecord::Base.connection.tables.each do |table|
    ActiveRecord::Base.connection.drop_table(table)
  end
end

class ParanoidTime < ActiveRecord::Base
  acts_as_paranoid
  validates_uniqueness_of :name

  has_many :paranoid_has_many_dependants, :dependent => :destroy
  has_many :paranoid_booleans, :dependent => :destroy
  has_many :not_paranoids, :dependent => :delete_all

  has_one :has_one_not_paranoid, :dependent => :destroy

  belongs_to :not_paranoid, :dependent => :destroy
end

default_config = ActsAsParanoid::DEFAULT_CONFIG.dup
ActsAsParanoid.default_config = { :column_type => "boolean", :column => "is_deleted" }
class ParanoidBoolean < ActiveRecord::Base
  acts_as_paranoid
  validates_as_paranoid
  validates_uniqueness_of_without_deleted :name

  belongs_to :paranoid_time
  has_one :paranoid_has_one_dependant, :dependent => :destroy
end

ActsAsParanoid.default_config = {
  :columns => [
    { :column => "is_deleted", :column_type => "boolean" },
    { :column => "deleted_at", :column_type => "time" }
  ]
}
class ParanoidBooleanAndDateDefaultConfig < ActiveRecord::Base
  self.table_name = :paranoid_boolean_and_dates
  acts_as_paranoid
end
Kernel.silence_warnings { ActsAsParanoid::DEFAULT_CONFIG = default_config }

class ParanoidBooleanAndDate < ActiveRecord::Base
  acts_as_paranoid :columns => [
    { :column_type => "boolean", :column => "is_deleted" },
    { :column_type => "time"   , :column => "deleted_at" }
  ]
end

class ParanoidString < ActiveRecord::Base
  acts_as_paranoid :column_type => "string", :column => "deleted", :deleted_value => "dead"
end

class NotParanoid < ActiveRecord::Base
end

class HasOneNotParanoid < ActiveRecord::Base
end

class ParanoidHasManyDependant < ActiveRecord::Base
  acts_as_paranoid
  belongs_to :paranoid_time

  belongs_to :paranoid_belongs_dependant, :dependent => :destroy
end

class ParanoidBelongsDependant < ActiveRecord::Base
  acts_as_paranoid

  has_many :paranoid_has_many_dependants
end

class ParanoidHasOneDependant < ActiveRecord::Base
  acts_as_paranoid

  belongs_to :paranoid_boolean
end

class ParanoidWithCallback < ActiveRecord::Base
  acts_as_paranoid

  attr_accessor :called_before_destroy, :called_after_destroy, :called_after_commit_on_destroy
  attr_accessor :called_before_recover, :called_after_recover

  before_destroy :call_me_before_destroy
  after_destroy :call_me_after_destroy

  after_commit :call_me_after_commit_on_destroy, :on => :destroy

  before_recover :call_me_before_recover
  after_recover :call_me_after_recover

  def initialize(*attrs)
    @called_before_destroy = @called_after_destroy = @called_after_commit_on_destroy = false
    super(*attrs)
  end

  def call_me_before_destroy
    @called_before_destroy = true
  end

  def call_me_after_destroy
    @called_after_destroy = true
  end

  def call_me_after_commit_on_destroy
    @called_after_commit_on_destroy = true
  end

  def call_me_before_recover
    @called_before_recover = true
  end

  def call_me_after_recover
    @called_after_recover = true
  end
end

class ParanoidDestroyCompany < ActiveRecord::Base
  acts_as_paranoid
  validates :name, :presence => true
  has_many :paranoid_products, :dependent => :destroy
end

class ParanoidDeleteCompany < ActiveRecord::Base
  acts_as_paranoid
  validates :name, :presence => true
  has_many :paranoid_products, :dependent => :delete_all
end

class ParanoidProduct < ActiveRecord::Base
  acts_as_paranoid
  belongs_to :paranoid_destroy_company
  belongs_to :paranoid_delete_company
  validates_presence_of :name
end

class SuperParanoid < ActiveRecord::Base
  acts_as_paranoid
  belongs_to :has_many_inherited_super_paranoidz
end

class HasManyInheritedSuperParanoidz < ActiveRecord::Base
  has_many :super_paranoidz, :class_name => "InheritedParanoid", :dependent => :destroy
end

class InheritedParanoid < SuperParanoid
  acts_as_paranoid
end

class ParanoidObserver < ActiveRecord::Observer
  observe :paranoid_with_callback

  attr_accessor :called_before_recover, :called_after_recover

  def before_recover(paranoid_object)
    self.called_before_recover = paranoid_object
  end

  def after_recover(paranoid_object)
    self.called_after_recover = paranoid_object
  end

  def reset
    self.called_before_recover = nil
    self.called_after_recover = nil
  end
end

class ParanoidManyManyParentLeft < ActiveRecord::Base
  has_many :paranoid_many_many_children
  has_many :paranoid_many_many_parent_rights, :through => :paranoid_many_many_children
end

class ParanoidManyManyParentRight < ActiveRecord::Base
  has_many :paranoid_many_many_children
  has_many :paranoid_many_many_parent_lefts, :through => :paranoid_many_many_children
end

class ParanoidManyManyChild < ActiveRecord::Base
  acts_as_paranoid
  belongs_to :paranoid_many_many_parent_left
  belongs_to :paranoid_many_many_parent_right
end

class ParanoidWithScopedValidation < ActiveRecord::Base
  acts_as_paranoid
  validates_uniqueness_of :name, :scope => :category
end


ParanoidWithCallback.add_observer(ParanoidObserver.instance)


class ParanoidBaseTest < ActiveSupport::TestCase
  def assert_empty(collection)
    assert(collection.respond_to?(:empty?) && collection.empty?)
  end

  def setup
    setup_db

    ["paranoid", "really paranoid", "extremely paranoid"].each do |name|
      ParanoidTime.create! :name => name
      ParanoidBoolean.create! :name => name
      ParanoidBooleanAndDate.create! :name => name
    end

    ParanoidString.create! :name => "strings can be paranoid"
    NotParanoid.create! :name => "no paranoid goals"
    ParanoidWithCallback.create! :name => "paranoid with callbacks"

    ParanoidObserver.instance.reset
  end

  def teardown
    teardown_db
  end
end
