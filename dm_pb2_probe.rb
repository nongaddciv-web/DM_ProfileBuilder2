module DM
module ProfileBuilder2
module Probe
  LOG_PATH = File.join(File.dirname(__FILE__), "dm_pb2_probe.log")
  @junction_mode = "continuous"
  @extrude_mode = "normal"
  @applying_junction = false
  @enable_experimental_split = false
  @segmenting_profile_member = false
  @segmenting_profile_member_ids = {}
  @segment_timer_token = 0
  @last_segmented_groups = []
  @last_segmented_points = []
  @last_segmented_mode = nil

  class << self
    attr_reader :junction_mode, :extrude_mode

    def log(message)
      File.open(LOG_PATH, "a") do |file|
        file.puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}")
      end
    rescue
      nil
    end

    def reset_log
      File.open(LOG_PATH, "w") do |file|
        file.puts("DM ProfileBuilder2 probe")
        file.puts("Plugin path: #{File.dirname(__FILE__)}")
        file.puts("SketchUp: #{Sketchup.version rescue 'unknown'}")
        file.puts("Ruby: #{RUBY_VERSION}")
        file.puts("")
      end
    rescue
      nil
    end

    def patch_dialog_callbacks(klass_name)
      return unless defined?(UI)
      return unless UI.const_defined?(klass_name)

      klass = UI.const_get(klass_name)
      return if klass.method_defined?(:dm_pb2_original_add_action_callback)
      return unless klass.method_defined?(:add_action_callback)

      klass.class_eval do
        alias_method :dm_pb2_original_add_action_callback, :add_action_callback

        def add_action_callback(callback_name, &block)
          begin
            DM::ProfileBuilder2::Probe.log(
              "callback #{self.class}##{object_id}: #{callback_name}"
            )
          rescue
          end

          wrapped_block = Proc.new do |*args|
            begin
              DM::ProfileBuilder2::Probe.log_callback_invocation(callback_name, args)
            rescue
            end
            block.call(*args)
          end

          dm_pb2_original_add_action_callback(callback_name, &wrapped_block)
        end
      end

      log("patched UI::#{klass_name}#add_action_callback")
    rescue => error
      log("failed to patch UI::#{klass_name}: #{error.class}: #{error.message}")
    end

    def install_callback_probe
      reset_log
      patch_dialog_callbacks(:WebDialog)
      patch_dialog_callbacks(:HtmlDialog)
    end

    def describe_arg(arg)
      case arg
      when String, Numeric, TrueClass, FalseClass, NilClass
        arg.inspect
      else
        "#{arg.class}##{arg.object_id}"
      end
    rescue
      "uninspectable"
    end

    def log_callback_invocation(callback_name, args)
      log("invoke callback #{callback_name}: #{args.map { |arg| describe_arg(arg) }.join(', ')}")
      return unless callback_name.to_s == "ValueChanged"

      value = args.last.to_s
      id, raw_value = value.split("|", 2)
      case id
      when "junctionMode"
        @junction_mode = raw_value.to_s
        log("state junction_mode=#{@junction_mode}")
      when "extrudeMode"
        @extrude_mode = raw_value.to_s
        log("state extrude_mode=#{@extrude_mode}")
      end
    rescue => error
      log("callback invocation log failed: #{error.class}: #{error.message}")
    end

    def describe_entity(entity)
      return "nil" if entity.nil?
      parts = ["#{entity.class}##{entity.object_id}"]
      parts << "valid=#{entity.valid?}" if entity.respond_to?(:valid?)
      parts << "entityID=#{entity.entityID}" if entity.respond_to?(:entityID)
      parts.join(" ")
    rescue
      "#{entity.class}##{entity.object_id}"
    end

    def describe_chain(chain)
      return "nil" if chain.nil?
      details = ["#{chain.class}##{chain.object_id}"]
      details << "length=#{chain.length}" if chain.respond_to?(:length)
      details << "num_points=#{chain.num_points}" if chain.respond_to?(:num_points)
      details << "closed=#{chain.closed_path?}" if chain.respond_to?(:closed_path?)
      details.join(" ")
    rescue => error
      "#{chain.class}##{chain.object_id} chain_error=#{error.class}:#{error.message}"
    end

    def describe_profile_member(pm)
      details = []
      details << "name=#{pm.name.inspect}" if pm.respond_to?(:name)
      details << "segments=#{pm.num_segments}" if pm.respond_to?(:num_segments)
      details << "length=#{pm.length}" if pm.respond_to?(:length)
      details << "chain=(#{describe_chain(pm.chain)})" if pm.respond_to?(:chain)
      details << "instance=(#{describe_entity(pm.instance)})" if pm.respond_to?(:instance)
      details.join(" ")
    rescue => error
      "pm_error=#{error.class}:#{error.message}"
    end

    def apply_junction_mode(profile_member)
      return if @applying_junction
      return unless @enable_experimental_split
      return if @junction_mode.to_s == "continuous"
      return unless profile_member.respond_to?(:num_segments)
      return unless profile_member.respond_to?(:split)
      return if profile_member.num_segments.to_i < 2

      @applying_junction = true
      log("apply junction #{@junction_mode} to #{describe_profile_member(profile_member)}")

      result = profile_member.split
      log("split result=#{describe_arg(result)}")

      if @junction_mode.to_s == "miter"
        log("miter mode: using ProfileBuilder split output as segmented joined geometry")
      else
        log("butt mode: using ProfileBuilder split output as segmented butt geometry")
      end
    rescue => error
      log("apply junction failed: #{error.class}: #{error.message}")
      log(error.backtrace.first(8).join("\n")) if error.respond_to?(:backtrace) && error.backtrace
    ensure
      @applying_junction = false
    end

    def chain_points(chain)
      return [] unless chain.respond_to?(:length) && chain.respond_to?(:[])

      points = []
      (0...chain.length.to_i).each do |index|
        point = chain[index]
        points << point if point
      end
      points
    rescue => error
      log("chain_points failed: #{error.class}: #{error.message}")
      []
    end

    def same_point?(point_a, point_b)
      return false unless point_a && point_b
      point_a.distance(point_b) < 0.001
    rescue
      false
    end

    def prefix_points?(short_points, long_points)
      return false if short_points.empty?
      return false unless long_points.length > short_points.length

      short_points.each_with_index do |point, index|
        return false unless same_point?(point, long_points[index])
      end

      true
    end

    def erase_entities(entities)
      entities.to_a.each do |entity|
        entity.erase! if entity.valid?
      end
    rescue => error
      log("erase_entities failed: #{error.class}: #{error.message}")
    end

    def erase_group_list(groups, reason)
      erased = 0
      groups.each do |group|
        next unless group && group.valid?

        group.erase!
        erased += 1
      end

      log("erased #{erased} segment groups: #{reason}") if erased > 0
    rescue => error
      log("erase_group_list failed: #{error.class}: #{error.message}")
    end

    def clear_superseded_segment_groups(current_points)
      return unless @last_segmented_mode.to_s == @junction_mode.to_s
      return unless prefix_points?(@last_segmented_points, current_points)

      erase_group_list(@last_segmented_groups, "path continued after tentative segmentation")
      @last_segmented_groups = []
      @last_segmented_points = []
      @last_segmented_mode = nil
    end

    def parent_entities_for_group(group)
      parent = group.parent if group.respond_to?(:parent)
      return parent.entities if parent.respond_to?(:entities)
      return parent if parent.is_a?(Sketchup::Entities)

      Sketchup.active_model.active_entities
    rescue
      Sketchup.active_model.active_entities
    end

    def copy_group_attributes(source_group, target_group, segment_index)
      return unless source_group && target_group

      target_group.name = "#{source_group.name}_#{segment_index + 1}" if source_group.respond_to?(:name) && source_group.name.to_s.length > 0
      target_group.layer = source_group.layer if source_group.respond_to?(:layer) && target_group.respond_to?(:layer=)
      target_group.material = source_group.material if source_group.respond_to?(:material) && source_group.material && target_group.respond_to?(:material=)
    rescue => error
      log("copy_group_attributes failed: #{error.class}: #{error.message}")
    end

    def segment_chain(point_a, point_b)
      chain = DM::ProfileBuilder2::Chain.new([point_a, point_b])
      chain.set_path([point_a, point_b]) if chain.respond_to?(:set_path) && chain.length.to_i < 2
      chain
    rescue => error
      log("segment_chain failed: #{error.class}: #{error.message}")
      nil
    end

    def vector_between(point_a, point_b)
      return nil unless point_a && point_b
      vector = point_b - point_a
      return nil unless vector.respond_to?(:length) && vector.length.to_f > 1e-6
      vector.normalize!
      vector
    rescue => error
      log("vector_between failed: #{error.class}: #{error.message}")
      nil
    end

    def perpendicular_plane(point, direction)
      return nil unless point && direction
      return nil unless direction.respond_to?(:length) && direction.length.to_f > 1e-6
      [point, direction]
    rescue => error
      log("perpendicular_plane failed: #{error.class}: #{error.message}")
      nil
    end

    def miter_plane(prev_point, point, next_point)
      in_vector = vector_between(prev_point, point)
      out_vector = vector_between(point, next_point)
      return nil unless in_vector && out_vector

      normal = in_vector + out_vector
      if !normal.respond_to?(:length) || normal.length.to_f <= 1e-6
        normal = out_vector
        return nil unless normal.respond_to?(:length) && normal.length.to_f > 1e-6
      end
      normal.normalize!
      [point, normal]
    rescue => error
      log("miter_plane failed: #{error.class}: #{error.message}")
      nil
    end

    def butt_start_plane(points, index)
      perpendicular_plane(points[index], vector_between(points[index], points[index + 1]))
    end

    def butt_end_plane(points, index)
      perpendicular_plane(points[index + 1], vector_between(points[index], points[index + 1]))
    end

    def trim_segment_member(segment_member, start_plane, end_plane)
      return unless segment_member

      if start_plane
        segment_member.trim_to_plane(start_plane, 0)
        log("  trimmed start cap")
      end

      if end_plane
        segment_member.trim_to_plane(end_plane, 1)
        log("  trimmed end cap")
      end
    rescue => error
      log("trim_segment_member failed: #{error.class}: #{error.message}")
      log(error.backtrace.first(6).join("\n")) if error.respond_to?(:backtrace) && error.backtrace
    end

    def draw_path_segment_group(profile_member, parent_entities, original_group, points, index)
      segment_group = parent_entities.add_group
      copy_group_attributes(original_group, segment_group, index)

      extruder = DM::ProfileBuilder2::PathExtruder.new
      extruder.profile = profile_member.profile
      extruder.path = [points[index], points[index + 1]]
      # Snapshot entity objects before extrusion to detect where geometry is created
      model_entities_before = Sketchup.active_model.entities.to_a
      group_entities_before = segment_group.entities.to_a

      extruder.extrude_along_path(segment_group.entities)

      model_entities_after = Sketchup.active_model.entities.to_a
      group_entities_after = segment_group.entities.to_a

      created_in_model = model_entities_after - model_entities_before
      created_in_group = group_entities_after - group_entities_before
      log("extrude created #{created_in_group.length} entities in group, #{created_in_model.length} in model root")

      if created_in_model.length > 0
        log("WARNING: extruder created entities at model root: attempting to move into segment_group")
        # Log detailed info for each created root entity to aid debugging
        created_in_model.each_with_index do |ent, i|
          begin
            next unless ent
            info = []
            info << "[#{i+1}/#{created_in_model.length}] class=#{ent.class}"
            info << "valid=#{ent.valid?}" if ent.respond_to?(:valid?)
            info << "entityID=#{ent.entityID}" if ent.respond_to?(:entityID)
            if ent.respond_to?(:bounds)
              b = ent.bounds
              if b
                info << "bounds_center=#{b.center.to_a}" rescue nil
                info << "bounds_width=#{b.width.to_f.round(6)}" rescue nil
                info << "bounds_height=#{b.height.to_f.round(6)}" rescue nil
              end
            end
            if ent.respond_to?(:transformation)
              t = ent.transformation rescue nil
              info << "transformation=#{t.to_a}" if t
            end
            # For faces/edges, include vertex count / edge length hints
            if ent.is_a?(Sketchup::Face)
              verts = ent.vertices rescue []
              info << "verts=#{verts.length}"
            elsif ent.is_a?(Sketchup::Edge)
              info << "edge_length=#{(ent.length rescue 'unknown')}"
            end
            log(info.join(' | '))
          rescue => e
            log("failed describing root-created entity: #{e.class}: #{e.message}")
          end
        end

        moved = 0
        begin
          Sketchup.active_model.start_operation('Move extruder root entities', true)
          created_in_model.each do |ent|
            next unless ent && ent.valid?
            begin
              if ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
                defn = ent.definition rescue nil
                trans = ent.transformation rescue nil
                if defn
                  segment_group.entities.add_instance(defn, trans)
                  ent.erase! if ent.valid?
                  moved += 1
                  log("moved instance into group: #{describe_entity(ent)}")
                else
                  log("cannot move instance (no definition): #{describe_entity(ent)}")
                end
              else
                # Non-instance entities (edges/faces) can't be reparented easily; log and skip
                log("skipping non-instance entity during move: #{describe_entity(ent)}")
              end
            rescue => e
              log("failed moving entity: #{e.class}: #{e.message}")
            end
          end
        rescue => e
          log("move operation failed: #{e.class}: #{e.message}")
        ensure
          begin
            Sketchup.active_model.commit_operation
          rescue
          end
        end

        log("moved #{moved}/#{created_in_model.length} root-created entities into segment_group")
      end

      if segment_group.entities.length.to_i == 0
        segment_group.erase! if segment_group.valid?
        return nil
      end

      # Determine trimming planes based on junction mode
      start_plane = nil
      end_plane = nil
      if @junction_mode.to_s == "miter"
        prev_point = points[index - 1] if index > 0
        next_point = points[index + 2] if (index + 2) < points.length
        start_plane = miter_plane(prev_point, points[index], points[index + 1]) if prev_point
        end_plane = miter_plane(points[index], points[index + 1], next_point) if next_point
      elsif @junction_mode.to_s == "butt"
        start_plane = butt_start_plane(points, index)
        end_plane = butt_end_plane(points, index)
      end

      # Attempt to trim any created profile-member-like entities inside the group
      segment_group.entities.to_a.each do |ent|
        begin
          trim_segment_member(ent, start_plane, end_plane) if ent.respond_to?(:trim_to_plane)
        rescue => e
          log("trim on entity failed: #{e.class}: #{e.message}")
        end
      end

      segment_group
    rescue => error
      log("draw_path_segment_group failed: #{error.class}: #{error.message}")
      log(error.backtrace.first(6).join("\n")) if error.respond_to?(:backtrace) && error.backtrace
      segment_group.erase! if segment_group && segment_group.valid?
      nil
    end

    def entity_key(entity)
      entity.respond_to?(:entityID) ? entity.entityID : entity.object_id
    rescue
         Get-Content 'c:\Users\ssbno\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\DM_ProfileBuilder2\dm_pb2_probe.log' -Tail 200 -Wait   entity.object_id
    end

    def snapshot_entities(entities)
      keys = {}
      entities.to_a.each { |entity| keys[entity_key(entity)] = true }
      keys
    rescue
      {}
    end

    def erase_unexpected_new_entities(entities, before_keys, keep_entities)
      keep_keys = {}
      keep_entities.each { |entity| keep_keys[entity_key(entity)] = true if entity && entity.valid? }

      erased = 0
      entities.to_a.each do |entity|
        next unless entity.valid?
        key = entity_key(entity)
        next if before_keys[key] || keep_keys[key]

        entity.erase!
        erased += 1
      end

      log("erased #{erased} unexpected new entities") if erased > 0
    rescue => error
      log("erase_unexpected_new_entities failed: #{error.class}: #{error.message}")
    end

    def draw_segmented_groups(profile_member)
      return if @segmenting_profile_member
      return if @junction_mode.to_s == "continuous"
      return unless defined?(DM::ProfileBuilder2::PathExtruder)
      return unless profile_member.respond_to?(:chain)
      return unless profile_member.respond_to?(:profile)
      return unless profile_member.respond_to?(:instance)

      points = chain_points(profile_member.chain)
      return if points.length < 3

      @segmenting_profile_member = true
      log("segment groups #{@junction_mode}: points=#{points.length} #{describe_profile_member(profile_member)}")

      original_group = profile_member.instance
      return unless original_group && original_group.valid?

      parent_entities = parent_entities_for_group(original_group)
      before_entities = snapshot_entities(parent_entities)

      segment_groups = []

      (0...(points.length - 1)).each do |index|
        segment_group = draw_path_segment_group(profile_member, parent_entities, original_group, points, index)
        segment_groups << segment_group if segment_group && segment_group.valid?

        log("  drew path segment group #{index + 1}/#{points.length - 1}: #{describe_entity(segment_group)}")
      end

      if segment_groups.length == points.length - 1
        erase_unexpected_new_entities(parent_entities, before_entities, segment_groups + [original_group])
        original_group.erase! if original_group.valid?
        @last_segmented_groups = segment_groups.dup
        @last_segmented_points = points.dup
        @last_segmented_mode = @junction_mode.to_s
        log("erased original grouped member after segment replacement")
      else
        segment_groups.each { |group| group.erase! if group && group.valid? }
        log("kept original grouped member; created #{segment_groups.length}/#{points.length - 1} segment groups")
      end
    rescue => error
      log("segment groups failed: #{error.class}: #{error.message}")
      log(error.backtrace.first(8).join("\n")) if error.respond_to?(:backtrace) && error.backtrace
    ensure
      @segmenting_profile_member = false
    end

    def apply_segmented_groups_once(profile_member)
      return unless profile_member.respond_to?(:instance)
      instance = profile_member.instance
      return unless instance && instance.valid?

      entity_id = instance.entityID
      return if @segmenting_profile_member_ids[entity_id]

      return unless profile_member.respond_to?(:chain)
      return if chain_points(profile_member.chain).length < 3

      @segmenting_profile_member_ids[entity_id] = true
      draw_segmented_groups(profile_member)
    end

    def schedule_segmented_groups(profile_member)
      return if @junction_mode.to_s == "continuous"
      return unless defined?(UI)

      current_points = profile_member.respond_to?(:chain) ? chain_points(profile_member.chain) : []
      clear_superseded_segment_groups(current_points)

      @segment_timer_token += 1
      token = @segment_timer_token
      log("schedule segment groups token=#{token} mode=#{@junction_mode} #{describe_profile_member(profile_member)}")

      UI.start_timer(4.0, false) do
        begin
          if token == @segment_timer_token
            log("run segment groups token=#{token}")
            apply_segmented_groups_once(profile_member)
          else
            log("skip stale segment groups token=#{token}; latest=#{@segment_timer_token}")
          end
        rescue => error
          log("scheduled segment groups failed: #{error.class}: #{error.message}")
          log(error.backtrace.first(8).join("\n")) if error.respond_to?(:backtrace) && error.backtrace
        end
      end
    rescue => error
      log("schedule_segmented_groups failed: #{error.class}: #{error.message}")
    end

    def trace_instance_method(klass, method_name)
      original = "dm_pb2_probe_original_#{method_name}".to_sym
      return unless klass.method_defined?(method_name)
      return if klass.method_defined?(original)

      klass.class_eval do
        alias_method original, method_name

        define_method(method_name) do |*args, &block|
          begin
            DM::ProfileBuilder2::Probe.log(
              "enter #{klass}##{method_name} args=#{args.map { |arg| DM::ProfileBuilder2::Probe.describe_arg(arg) }.join(', ')} " \
              "state junction=#{DM::ProfileBuilder2::Probe.junction_mode} extrude=#{DM::ProfileBuilder2::Probe.extrude_mode}"
            )
            if self.is_a?(DM::ProfileBuilder2::ProfileMember)
              DM::ProfileBuilder2::Probe.log("  pm before #{DM::ProfileBuilder2::Probe.describe_profile_member(self)}")
            elsif respond_to?(:pmpi)
              DM::ProfileBuilder2::Probe.log("  pmpi=#{DM::ProfileBuilder2::Probe.describe_arg(pmpi)}")
            end
          rescue => error
            DM::ProfileBuilder2::Probe.log("  trace before failed: #{error.class}: #{error.message}") rescue nil
          end

          result = send(original, *args, &block)

          begin
            DM::ProfileBuilder2::Probe.log("leave #{klass}##{method_name} result=#{DM::ProfileBuilder2::Probe.describe_arg(result)}")
            if self.is_a?(DM::ProfileBuilder2::ProfileMember)
              DM::ProfileBuilder2::Probe.log("  pm after #{DM::ProfileBuilder2::Probe.describe_profile_member(self)}")
            end
            if klass == DM::ProfileBuilder2::ProfileMember && method_name == :draw
              DM::ProfileBuilder2::Probe.apply_junction_mode(self)
            end
            if klass == DM::ProfileBuilder2::ProfileBuilderTool && method_name == :place_member && result.is_a?(DM::ProfileBuilder2::ProfileMember)
              DM::ProfileBuilder2::Probe.schedule_segmented_groups(result)
            end
          rescue => error
            DM::ProfileBuilder2::Probe.log("  trace after failed: #{error.class}: #{error.message}") rescue nil
          end

          result
        end
      end

      log("tracing #{klass}##{method_name}")
    rescue => error
      log("failed tracing #{klass}##{method_name}: #{error.class}: #{error.message}")
    end

    def install_method_traces
      trace_instance_method(DM::ProfileBuilder2::ProfileBuilderTool, :place_member) if defined?(DM::ProfileBuilder2::ProfileBuilderTool)
      trace_instance_method(DM::ProfileBuilder2::ProfileBuilderTool, :validate_create_along_path) if defined?(DM::ProfileBuilder2::ProfileBuilderTool)
      trace_instance_method(DM::ProfileBuilder2::ProfileBuilderTool, :getValuesFromSU) if defined?(DM::ProfileBuilder2::ProfileBuilderTool)

      if defined?(DM::ProfileBuilder2::ProfileMember)
        [:draw, :split, :trim_to, :trim_to_plane, :set_chain, :set_from_profile!].each do |method_name|
          trace_instance_method(DM::ProfileBuilder2::ProfileMember, method_name)
        end
      end

      if defined?(DM::ProfileBuilder2::PathExtruder)
        [:extrude_along_path, :extrude_current_edge, :draw_start_cap_face, :draw_end_cap_face].each do |method_name|
          trace_instance_method(DM::ProfileBuilder2::PathExtruder, method_name)
        end
      end
    end

    def log_method_signature(klass, method_name, singleton = false)
      method_object = singleton ? klass.method(method_name) : klass.instance_method(method_name)
      log("signature #{klass}#{singleton ? '.' : '#'}#{method_name} arity=#{method_object.arity} parameters=#{method_object.parameters.inspect} source=#{method_object.source_location.inspect}")
    rescue => error
      log("signature failed #{klass}#{singleton ? '.' : '#'}#{method_name}: #{error.class}: #{error.message}")
    end

    def dump_method_signatures
      log("")
      log("method signatures")
      if defined?(DM::ProfileBuilder2::ProfileMember)
        [:initialize, :split, :trim_to, :trim_to_plane, :set_chain, :draw, :set_from_profile!].each do |method_name|
          log_method_signature(DM::ProfileBuilder2::ProfileMember, method_name)
        end
        [:add].each do |method_name|
          log_method_signature(DM::ProfileBuilder2::ProfileMember, method_name, true)
        end
      end

      if defined?(DM::ProfileBuilder2::Chain)
        [:initialize, :add, :set, :set_path, :[], :[]=].each do |method_name|
          log_method_signature(DM::ProfileBuilder2::Chain, method_name)
        end
      end

      if defined?(DM::ProfileBuilder2::ProfileBuilderTool)
        [:initialize, :place_member, :profile, :pmpi, :get_selected_edges].each do |method_name|
          log_method_signature(DM::ProfileBuilder2::ProfileBuilderTool, method_name)
        end
      end

      if defined?(DM::ProfileBuilder2::PathExtruder)
        [:initialize, :path=, :profile=, :extrude_along_path, :extrude_current_edge].each do |method_name|
          log_method_signature(DM::ProfileBuilder2::PathExtruder, method_name)
        end
      end
    end

    def object_name(object)
      object.name
    rescue
      nil
    end

    def interesting_name?(name)
      name && (name.index("DM::ProfileBuilder2") == 0 || name.index("ProfileBuilder"))
    end

    def dump_methods(object)
      method_names = []
      method_names += object.methods(false).map { |name| "self.#{name}" }
      method_names += object.instance_methods(false).map { |name| "##{name}" } if object.respond_to?(:instance_methods)
      method_names.sort.each { |name| log("  method #{name}") }
    rescue => error
      log("  method dump failed: #{error.class}: #{error.message}")
    end

    def dump_constants(namespace, prefix)
      namespace.constants(false).sort.each do |const_name|
        value = namespace.const_get(const_name)
        full_name = "#{prefix}::#{const_name}"
        next unless value.is_a?(Module)

        log("constant #{full_name} < #{value.class}")
        dump_methods(value)
      rescue => error
        log("constant #{full_name} failed: #{error.class}: #{error.message}")
      end
    rescue => error
      log("constant dump failed for #{prefix}: #{error.class}: #{error.message}")
    end

    def dump_object_space
      log("")
      log("loaded modules/classes")

      objects = []
      ObjectSpace.each_object(Module) do |object|
        name = object_name(object)
        objects << object if interesting_name?(name)
      end

      objects.sort_by { |object| object_name(object).to_s }.each do |object|
        log("#{object.class} #{object_name(object)}")
        dump_methods(object)
      end
    rescue => error
      log("object space dump failed: #{error.class}: #{error.message}")
    end

    def after_load
      log("")
      log("after encoded files loaded")
      dump_constants(DM::ProfileBuilder2, "DM::ProfileBuilder2")
      dump_object_space
      dump_method_signatures
      install_method_traces
      log("")
      log("probe complete")
    rescue => error
      log("after_load failed: #{error.class}: #{error.message}")
    end
  end
end
end
end

DM::ProfileBuilder2::Probe.install_callback_probe
