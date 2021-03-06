class XmlParser < XmlBase
  @xml = {}

  # @return [String] the file's basename without extension
  attr_reader :basename
  # @return [Nokogiri::XML::Node] the XML schema
  attr_reader :schema

  # @param [String] path the path to the XSD file
  # @param [Boolean] follow whether to lookup references in imports or includes
  def initialize(path, follow: true)
    @basename = File.basename(path, '.xsd')
    @schemas = import(path).values
    @schema = @schemas[0]
    @trees = {}

    activate(:main, follow: follow)
  end

  # Sets and initializes the active tree.
  #
  # @param [Symbol] active the tree to activate
  # @param [Boolean] follow whether to lookup references in imports or includes
  # @param [Boolean] reset whether to reset the tree
  def activate(active, follow: true, reset: false)
    @active = active
    if !@trees.key?(active)
      @trees[active] = {tree: [], follow: follow}
    elsif reset
      @trees[active][:tree] = []
    end
  end

  # @return [Array<TreeNode>] the active tree
  def tree
    @trees[@active][:tree]
  end

  # @return [Boolean] whether to lookup references in imports or includes
  def follow?
    @trees[@active][:follow]
  end

  # Returns the built tree as a CSV.
  #
  # @return [String] the CSV
  def to_csv
    mappings = {}

    rows = [%w(index) + HEADERS]

    rows += tree.map do |node|
      attributes = node.attributes.dup

      index0 = attributes[:index0]
      if !attributes.key?(:index1) && attributes[:annotation] && attributes[:annotation][/\ASection ([IV]+)/] && Integer === attributes[:index0]
        mappings[index0] = $1
      end
      if mappings.key?(index0)
        attributes[:index0] = mappings[index0]
      end

      minOccurs = attributes[:minOccurs] || 1
      maxOccurs = attributes[:maxOccurs] || 1
      if minOccurs != 1 || maxOccurs != 1
        attributes[:cardinality] = "[#{minOccurs}, #{maxOccurs}]"
      end

      if attributes.key?(:enumeration)
        attributes[:enumeration] = attributes[:enumeration].join('|')
      end

      [attributes.values_at(*LOCATORS).compact.join('.')] + attributes.values_at(*HEADERS)
    end

    rows = rows.transpose.reject{ |row| row.drop(1).all?(&:nil?) }.transpose

    CSV.generate do |csv|
      rows.each do |row|
        csv << row
      end
    end
  end

  # Prints to standard error if the condition isn't met.
  #
  # @param condition
  # @param [String] message
  # @param [Nokogiri::XML::Node] node a node
  def assert(condition, message='', node=nil)
    if !condition
      message = "#{@basename}: #{message}"
      if node
        message += " at #{node.path}: #{node.to_s[0..2000]}"
      end
      $stderr.puts message
    end
  end

  # Prints to standard error if the actual value isn't the expected value.
  def assert_equal(actual, expected, message='', node=nil)
    assert actual == expected, "expected #{expected}, got #{actual} #{message}", node
  end

  # Prints to standard error if the first value is not included in the second value.
  def assert_in(first, second, message='', node=nil)
    assert Array === second && second.include?(first), "expected #{second} to include '#{first}' #{message}", node
  end

  # Prints to standard error if the node has children.
  #
  # @param [Nokogiri::XML::Node] node a node
  def assert_leaf(node)
    assert node.element_children.empty?, 'expected no children', node
  end

  # Checks whether a node set meets expectations.
  #
  # `:size` and `:xml` are always tested. If `:name_only` is set, attributes and children are not tested. If `:index`
  # is set, only the node at that index is tested. Otherwise, all options and all nodes are tested.
  #
  # @param [Nokogiri::XML::NodeSet] ns a node set
  # @param [Hash] opts
  # @option opts [Integer, Range] :size The expected number of nodes in the node set.
  # @option opts [Hash] :xml A hash of array indices/slices to XML strings.
  # @option opts [Boolean] :name_only Only test `:size`, `:xml` and `:names`.
  # @option opts [Integer] :index The index of the single node to test.
  # @option opts [String] :names The allowed tag names.
  # @option opts [Array<String>] :attributes The expected attribute names. `[]` by default.
  # @option opts [Array<String>] :required The names of required attributes.
  # @option opts [Array<String>] :disjoint The names of disjoint required attributes.
  # @option opts [Array<String>] :optional The names of optional attributes.
  # @option opts [String, true] :children The nodes are expected to have:
  #   * If `"any"`, anything
  #   * If `true`: children
  #   * If `"text"`: no tag children
  #   * If omitted: no children
  # @return the node set
  # @raise if the arguments are not properly set
  def node_set(ns, opts)
    if opts.key?(:attributes) && (opts.key?(:required) || opts.key?(:optional))
      raise 'must not set both :attributes and any of :required, :optional'
    end
    if opts.key?(:size) && (Range === opts[:size] && opts[:size].last > 1 || Integer === opts[:size] && opts[:size] > 1) && opts.key?(:index) && !opts.key?(:xml)
      raise 'must set :xml if the maximum :size is greater than 1 and :index is set'
    end

    assert opts.fetch(:size) === ns.size, "expected #{opts[:size]}, got #{ns.size} elements: #{ns}"

    if opts[:xml]
      opts[:xml].each do |k, v|
        assert_equal ns[k].to_xml, v
      end
    end

    if opts.key?(:index)
      node(ns[opts[:index]], opts)
    else
      ns.each do |n|
        node(n, opts)
      end
    end

    ns
  end

  # Checks whether a node meets expectations.
  #
  # @param [Nokogiri::XML::Node] n
  # @param [Hash] opts
  # @see node_set
  def node(n, opts)
    assert_in n.name, opts.fetch(:names), 'tag name', n

    if !opts[:name_only]
      if opts.key?(:required) || opts.key?(:optional)
        allowed_attributes(n, opts.slice(:required, :optional))
      else
        allowed_attributes(n, required: opts.fetch(:attributes, []))
      end
    end

    if !opts[:name_only]
      assert !opts.key?(:children) && n.children.none? ||
             opts[:children] == 'text' && n.element_children.none? ||
             opts[:children] == true && n.children.any? ||
             opts[:children] == 'any', "expected #{opts[:children].inspect} children", n
    end
  end

  # Checks whether required attributes are present on a node and whether any attributes are unexpected.
  #
  # @param [Nokogiri::XML::Node] n
  # @param [Array<String>] :required The names of required attributes.
  # @param [Array<String>] :disjoint The names of disjoint required attributes.
  # @param [Array<String>] :optional The names of optional attributes.
  def allowed_attributes(n, required: [], disjoint: [], optional: [])
    required.each do |attribute|
      assert_in attribute, n.attributes.keys, 'required attribute name', n
    end

    assert disjoint.empty? || disjoint.one?{ |attribute| n.attributes.keys.include?(attribute) }, "expected one of #{disjoint.join(', ')}", n

    unexpected = n.attributes.keys - required - disjoint - optional
    assert unexpected.empty?, "unexpected attributes #{unexpected}", n
  end

  # @return [Symbol] the symbol for the locator at this depth
  # @raise if the depth of the locator is unexpected
  def key_for_depth(depth)
    key = "index#{depth + 1}".to_sym

    if !LOCATORS.include?(key)
      raise "missing property #{key}"
    end

    key
  end

  # @param [Nokogiri::XML::Node] node a node
  # @param [Hash] attributes
  def set_last(node, attributes)
    attributes.each do |key, value|
      # Exception to preserve length information.
      if key == :restriction && tree.last.attributes[key] == 'contact' && value == 'string_200'
        tree.last.attributes.delete(key)
      end

      was = tree.last.attributes[key]

      unless was &&
             # Don't overwrite if the restriction is a simpler type.
             key == :restriction && %w(xs:date xs:integer xs:nonNegativeInteger _4car _5car xs:string string_with_letter string_not_empty).include?(value) ||
             # Don't overwrite with the annotation of a simpler type.
             # common_2014.xsd expands "LEFTI" to "LEGAL, ECONOMIC, FINANCIAL AND TECHNICAL INFORMATION".
             key == :annotation && %w(_3car _4car string_not_empty lefti).include?(node['name']) ||
             # Don't overwrite with the pattern of a simpler type.
             key == :pattern && %w(string_not_empty).include?(node['name'])
        assert was.nil? || was == value, "unexpected #{key} = '#{value}' (was #{was})", node
        tree.last.attributes[key] = value
      end
    end
  end

  # Adds or merges entries to the tree.
  #
  # @see elements
  def enter(n, depth, opts)
    opts.delete(:enter)
    reference = opts.key?(:reference) && opts[:reference].split(':', 2).last # remove namespace
    if reference && reference == n['name']
      tree.last.merge(n, opts, except: %i(reference))
    elsif n.name == 'attribute' && n['name'] == 'CTYPE'
      tree.last.merge(n, opts, except: %i(reference tag name) + [key_for_depth(depth)])
    else
      tree << TreeNode.new(n, opts)
    end
  end

  # Annotates an entry in the built tree.
  #
  # @param [Nokogiri::XML::Node] node a node
  # @param [Array<String>] annotations the node's allowed annotation elements
  # @param [Boolean] discard whether to discard the annotation
  def annotate(node, annotations, discard: false)
    node = node.dup

    annotations.each do |name|
      n = node.element_children.find{ |child| child.name == name }

      if n
        case n.name
        when 'annotation'
          allowed_attributes(n)
          ns = node_set(n.element_children, size: 1, names: ['documentation'], optional: ['lang'], children: 'any') # discard lang ("en")
          attributes = {annotation: ns[0].text.split("\n").map(&:strip).join("\n").strip}

        when 'unique'
          allowed_attributes(n, required: ['name']) # discard name ("lg")
          ns = node_set(n.element_children, size: 2, index: 1, names: ['field'], attributes: ['xpath'], xml: {0 => '<xs:selector xpath="*"/>'})
          attributes = {unique: ns[1]['xpath']}

        else
          assert false, "unexpected #{n.name}", n
        end

        if !discard
          set_last(node, attributes)
        end

        n.unlink
      end
    end

    node
  end

  # Follows a `base`, `ref` or `type` attribute.
  #
  # @param [Boolean] optional whether the element may have neither references nor children
  # @see elements
  def follow(n, depth, opts, optional: false)
    matches = [n.key?('base'), n.key?('ref'), n.key?('type'), !n.key?('base') && n.element_children.any?].select(&:itself)
    assert matches.one? || optional && matches.none?, 'expected one of "base", "ref", "type", or children without "base"', n

    if opts[:reference]
      reference = opts[:reference]

      if reference[':']
        namespace, reference = reference.split(':', 2)
      end

      if !NO_FOLLOW.include?(reference) && namespace != 'xs'
        if n.key?('base') || n.key?('type')
          names = %w(complexType simpleType)
        elsif n.key?('ref')
          names = [n.name]
        end

        set = xpath(names.map{ |name| "./xs:#{name}[@name='#{reference}']" }.join('|'))

        if set
          ns = node_set(set, size: 1, names: names, name_only: true)
          elements(ns[0], depth, opts)
        end
      end
    end
  end

  # Builds the tree by traversing the XML from the given node.
  #
  # @param [Nokogiri::XML::Node] n a node
  # @param [Integer] depth the depth of the node
  # @param [Hash] opts locators and references
  # @option opts :index0
  # @option opts :index1
  # @option opts :index2
  # @option opts :index3
  # @option opts :index4
  # @option opts :index5
  # @option opts :index6
  # @option opts :index7
  # @option opts :extension
  # @option opts :restriction
  # @option opts :reference
  def elements(n, depth, opts)
    case n.name
      # Each case follows a rhythm of:
      #
      # * enter(n, depth, opts…   only element, group, attribute plus complexType, simpleType for common_2014.xsd
      # * allowed_attributes(n…
      # * n = annotate(n, …       except simpleContent, complexContent, attribute
      # * [base]                  only simpleType, simpleContent, complexContent
      # * [logic]
      # * children = node_set(n…  except simpleType
      # * children.…              except simpleType
      # * follow(n…               except sequence, choice, complexType
    when 'choice'
      allowed_attributes(n, optional: %w(minOccurs maxOccurs)) # discard minOccurs ("0"), maxOccurs (on p and text_ft_multi_lines_or_string only)
      n = annotate(n, ['annotation'])
      children = node_set(n.element_children, size: 1..6, names: %w(choice element group sequence), name_only: true)
      children.to_enum.with_index(97) do |c, i|
        elements(c, depth + 1, opts.merge(key_for_depth(depth) => i.chr))
      end

    when 'sequence'
      allowed_attributes(n, optional: %w(minOccurs)) # discard minOccurs ("0")
      n = annotate(n, ['annotation'])
      children = node_set(n.element_children, size: 1..16, names: %w(choice element group sequence), name_only: true)
      children.to_enum.with_index(1) do |c, i|
        elements(c, depth + 1, opts.merge(key_for_depth(depth) => i))
      end

    when 'group'
      enter(n, depth, opts)

      allowed_attributes(n, disjoint: %w(name ref), optional: %w(minOccurs maxOccurs))
      n = annotate(n, ['annotation'])
      children = node_set(n.element_children, size: 0..1, names: %w(choice sequence), children: true)
      children.each do |c|
        elements(c, depth, opts)
      end

      follow(n, depth, opts.merge(reference: n['ref']))

    when 'element'
      enter(n, depth, opts)

      allowed_attributes(n, disjoint: %w(name ref), optional: %w(type minOccurs maxOccurs))
      n = annotate(n, %w(annotation unique))
      children = node_set(n.element_children, size: 0..1, names: %w(complexType simpleType), name_only: true)
      children.each do |c|
        elements(c, depth, opts)
      end

      follow(n, depth, opts.merge(reference: n['ref'] || n['type']))

    when 'complexType'
      if opts[:enter]
        enter(n, depth, opts)
      end

      allowed_attributes(n, optional: %w(name mixed)) # discard name (referenced) and mixed (on p and text_ft_multi_lines_or_string only)
      n = annotate(n, ['annotation'])
      children = node_set(n.element_children, size: 0..2, names: %w(attribute choice group sequence complexContent simpleContent), name_only: true)
      children.each do |c|
        elements(c, depth, opts)
      end

    when 'simpleType'
      if opts[:enter]
        enter(n, depth, opts)
      end

      allowed_attributes(n, optional: ['name']) # discard name (referenced)
      n = annotate(n, ['annotation'])

      ns = node_set(n.element_children, size: 1, names: ['restriction'], attributes: ['base'], children: 'any')
      node = ns[0]
      base = node['base']

      children = node_set(node.element_children, size: 0..9999, names: RESTRICTIONS.map(&:to_s), attributes: ['value'], children: 'any')
      if children.any?
        restrictions = {enumeration: []}
        children.each do |c|
          c = annotate(c, ['annotation'], discard: NO_ANNOTATIONS.include?(n['name']))
          assert_leaf c

          key = c.name.to_sym
          value = c['value']

          if key == :enumeration
            restrictions[key] << value
          else
            restrictions[key] = value
          end
        end
        if restrictions[:enumeration].none?
          restrictions.delete(:enumeration)
        end
        set_last(n, restrictions.merge(restriction: base))
      end

      follow(node, depth, opts.merge(reference: base))

    when 'simpleContent'
      allowed_attributes(n)

      ns = node_set(n.element_children, size: 1, names: ['extension'], attributes: ['base'], children: true)
      node = ns[0]
      base = node['base']

      children = node_set(node.element_children, size: 1, names: ['attribute'], name_only: true)
      children.each do |c|
        elements(c, depth, opts.merge(extension: base))
      end

      follow(node, depth, opts.merge(reference: base))

    when 'complexContent'
      allowed_attributes(n)

      ns = node_set(n.element_children, size: 1, names: %w(extension restriction), attributes: ['base'], children: 'any')
      node = ns[0]
      base = node['base']

      case node.name
      when 'extension'
        additional = {extension: base}
        names = %w(attribute choice group sequence)
      when 'restriction'
        additional = {restriction: base}
        names = ['sequence']
      else
        assert false, "unexpected #{n.name}", n
      end

      if node.name == 'restriction' && !NO_CHILDREN.include?(node['base'])
        compare(node, depth, opts)
      end

      if node.name != 'restriction' || !NO_CHILDREN.include?(node['base'])
        children = node_set(node.element_children, size: 0..1, names: names, name_only: true)
        children.each do |c|
          elements(c, depth, opts.merge(additional))
        end
      end

      follow(node, depth, opts.merge(reference: base))

    when 'attribute'
      enter(n, depth, opts.merge(key_for_depth(depth) => '+'))

      allowed_attributes(n, required: ['name'], optional: %w(type use fixed))
      children = node_set(n.element_children, size: 0..1, names: ['simpleType'], children: true)
      children.each do |c|
        elements(c, depth, opts)
      end

      follow(n, depth, opts.merge(reference: n['type']), optional: true)

    else
      assert false, "unexpected #{n.name}", n
    end
  end

  def compare(node, depth, opts)
    def comparator(active)
      # :index0 may be natural numbers instead of roman numerals.
      # :index1 may be larger numbers due to additional tags.
      # :restriction and :reference will be swapped or nil.
      @trees[active][:tree].map{ |n| n.attributes.except(:index0, :index1, :restriction, :reference) }
    end

    activate(:restriction, reset: true)

    children = node_set(node.element_children, size: 0..1, names: ['sequence'], name_only: true)
    children.each do |c|
      elements(c, depth, opts.merge(restriction: node['base']))
    end

    activate(:follow, reset: true)

    tree << @trees[:main][:tree].last # initialize with the last node of the main tree, for annotations
    follow(node, depth, opts.merge(reference: node['base']))
    tree.shift

    a = comparator(:restriction)
    b = comparator(:follow)

    changed = a - b
    while changed.any? && b.any? # b will be empty if the type is included in NO_FOLLOW
      c = a.delete(changed.shift)
      d = b.delete_at(b.index{ |n| n[:name] == c[:name] })
      $stderr.puts "#{@basename}: #{node['base']}: changes #{c[:name]}: #{HashDiff.diff(d, c)}"
    end

    removed = b - a
    if removed.any?
      $stderr.puts "#{@basename} #{node['base']}: removes #{removed.map{ |n| n[:name] }}"
    end

    activate(:main)
  end
end
