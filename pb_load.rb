module DM

module ProfileBuilder2

this_dir=File.dirname(__FILE__)
PATH=this_dir

Sketchup::require(File.join(PATH,"dm_pb2_probe"))

files=["observers","mixins","profile_library","profile","profilemember","profileBuilder","assembly","lathe","trim",
	"extend","pb_mto","pathtools","pb_material","assembly_tool","picker","progressbar","browser"]

files.each {|f|	Sketchup::require(File.join(PATH,f))}

Probe.after_load if defined?(Probe)

end

end
