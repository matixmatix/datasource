module Datasource
  class Base
    class << self
      attr_accessor :_attributes, :_associations, :_update_scope, :_loaders, :_collection_context
      attr_writer :orm_klass

      def inherited(base)
        base._attributes = (_attributes || {}).dup
        base._associations = (_associations || {}).dup
        base._loaders = (_loaders || {}).dup
        base._collection_context = Class.new(_collection_context || CollectionContext)
      end

      def default_adapter
        @adapter ||= begin
          Datasource::Adapters.const_get(Datasource::Adapters.constants.first)
        end
      end

      def consumer_adapter
        @consumer_adapter = Datasource::ConsumerAdapters::ActiveModelSerializers
      end

      def orm_klass
        fail Datasource::Error, "Model class not set for #{name}. You should define it:\nclass YourDatasource\n  @orm_klass = MyModelClass\nend"
      end

      def primary_key
        :id
      end

      def reflection_select(reflection, parent_select, assoc_select)
        # append foreign key depending on assoication
        if reflection[:macro] == :belongs_to
          parent_select.push(reflection[:foreign_key])
        elsif [:has_many, :has_one].include?(reflection[:macro])
          assoc_select.push(reflection[:foreign_key])
        else
          fail Datasource::Error, "unsupported association type #{reflection[:macro]} - TODO"
        end
      end

      def collection(&block)
        _collection_context.class_exec(&block)
      end

    private
      def attributes(*attrs)
        attrs.each { |name| attribute(name) }
      end

      def associations(*assocs)
        assocs.each { |name| association(name) }
      end

      def association(name)
        @_associations[name.to_s] = true
      end

      def attribute(name, klass = nil)
        att = { name: name.to_s, klass: klass }
        @_attributes[att[:name]] = att
      end

      def update_scope(&block)
        # TODO: careful about scope module extension, to_a infinite recursion
        @_update_scope = block
      end

      def group_by_column(column, rows, remove_column = false)
        rows.inject({}) do |map, row|
          map[row[column]] = row
          row.delete(column) if remove_column
          map
        end
      end
    end

    attr_reader :scope, :expose_attributes, :expose_associations, :adapter

    def initialize(scope, adapter = nil)
      @adapter = adapter || self.class.default_adapter
      @scope =
        if self.class._update_scope
          self.class._update_scope.call(scope)
        else
          scope
        end
      @expose_attributes = []
      @expose_associations = {}
      @select_all_columns = false
      @params = {}
    end

    def params(*args)
      args.each do |arg|
        if arg.kind_of?(Hash)
          @params.deep_merge!(arg.symbolize_keys)
        elsif arg.is_a?(Symbol)
          @params.merge!(arg => true)
        else
          fail Datasource::Error, "unknown parameter type #{arg.class}"
        end
      end

      @params
    end

    def select_all_columns
      column_attributes = self.class._attributes.values.select do |att|
        att[:klass].nil?
      end
      columns = column_attributes.map { |att| att[:name] }
      select(*columns)
      @select_all_columns = true

      columns
    end

    def select_all
      attributes = self.class._attributes.keys
      select(*attributes)
      @select_all_columns = true

      attributes
    end

    def select(*names)
      newly_exposed_attributes = []
      missing_attributes = []
      names.each do |name|
        if name.kind_of?(Hash)
          name.each_pair do |assoc_name, assoc_select|
            assoc_name = assoc_name.to_s
            if self.class._associations.key?(assoc_name)
              @expose_associations[assoc_name] ||= []
              @expose_associations[assoc_name].concat(Array(assoc_select))
              @expose_associations[assoc_name].uniq!
            else
              missing_attributes << assoc_name
            end
          end
        else
          name = name.to_s
          if name == "*"
            select_all_columns
          elsif self.class._attributes.key?(name)
            unless @expose_attributes.include?(name)
              @expose_attributes.push(name)
              newly_exposed_attributes.push(name)
            end
          else
            missing_attributes << name
          end
        end
      end
      update_dependencies(newly_exposed_attributes) unless newly_exposed_attributes.empty?
      fail_missing_attributes(missing_attributes) unless Datasource.config.simple_mode || missing_attributes.empty?
      self
    end

    def fail_missing_attributes(names)
      message = if names.size > 1
        "attributes or associations #{names.join(', ')} don't exist "
      else
        "attribute or association #{names.first} doesn't exist "
      end
      message += "for #{self.class.orm_klass.name}, "
      message += "did you forget to call \"computed :#{names.first}, <dependencies>\" in your datasource_module?"
      fail Datasource::Error, message
    end

    def update_dependencies(names)
      scope_table = adapter.primary_scope_table(self)

      self.class._attributes.values.each do |att|
        next unless names.include?(att[:name])
        next unless att[:klass]

        if att[:klass].ancestors.include?(Attributes::ComputedAttribute)
          att[:klass]._depends.each_pair do |key, value|
            if key.to_s == scope_table
              select(*value)
            else
              select(key => value)
            end
          end
        elsif att[:klass].ancestors.include?(Attributes::QueryAttribute)
          att[:klass]._depends.each do |name|
            next if name == scope_table
            adapter.ensure_table_join!(self, name, att)
          end
        end
      end
    end

    def get_select_values
      scope_table = adapter.primary_scope_table(self)
      select_values = Set.new

      if @select_all_columns
        select_values.add("#{scope_table}.*")

        self.class._attributes.values.each do |att|
          if att[:klass] && attribute_exposed?(att[:name])
            if att[:klass].ancestors.include?(Attributes::QueryAttribute)
              select_values.add("(#{att[:klass].select_value}) as #{att[:name]}")
            end
          end
        end
      else
        select_values.add("#{scope_table}.#{self.class.primary_key}")

        self.class._attributes.values.each do |att|
          if attribute_exposed?(att[:name])
            if att[:klass] == nil
              select_values.add("#{scope_table}.#{att[:name]}")
            elsif att[:klass].ancestors.include?(Attributes::QueryAttribute)
              select_values.add("(#{att[:klass].select_value}) as #{att[:name]}")
            end
          end
        end
      end

      select_values.to_a
    end

    def attribute_exposed?(name)
      @expose_attributes.include?(name.to_s)
    end

    # assume records have all attributes selected (default ORM record)
    def can_upgrade?(records)
      query_attributes = @expose_attributes.select do |name|
        klass = self.class._attributes[name][:klass]
        if klass
          klass.ancestors.include?(Attributes::QueryAttribute)
        end
      end

      return true if query_attributes.empty?
      Array(records).all? do |record|
        query_attributes.all? do |name|
          adapter.has_attribute?(record, name)
        end
      end
    end

    def upgrade_records(records)
      adapter.upgrade_records(self, Array(records))
    end

    def get_collection_context(rows)
      self.class._collection_context.new(@scope, rows, self, @params)
    end

    def get_loader_dependencies
      @expose_attributes
      .map { |name|
        self.class._attributes[name]
      }.select { |att|
        att[:klass] && att[:klass].ancestors.include?(Attributes::ComputedAttribute)
      }.flat_map { |att|
        att[:klass]._loader_depends
      }.uniq
      .map { |loader_name|
        loader =
          self.class._loaders[loader_name] or
          fail Datasource::Error, "loader with name :#{loader_name} could not be found"
        [loader_name, loader]
      }
    end

    def results(rows = nil)
      rows ||= adapter.get_rows(self)
      collection_context = get_collection_context(rows)
      # use WeakRef to allow GC of rows?
      loaded_values = { _rows: rows }

      unless rows.empty?
        loader_dependencies = get_loader_dependencies.map do |(loader_name, loader)|
          loaded_values[loader_name] = loader.load(collection_context)
        end

        rows.each do |row|
          row._datasource_instance = self
          row._datasource_loaded = loaded_values
        end
      end

      rows
    end
  end
end
