#!/usr/bin/env ruby
# Generates CorlexExample.xcodeproj (the .xcodeproj is committed; this script is how it was made
# and how to change it): `ruby generate-project.rb` from this folder. Needs the `xcodeproj` gem
# (installed with CocoaPods).
require 'fileutils'
require 'xcodeproj'

root = __dir__
path = File.join(root, 'CorlexExample.xcodeproj')
FileUtils.rm_rf(path)

project = Xcodeproj::Project.new(path)
target = project.new_target(:application, 'CorlexExample', :ios, '15.0')

group = project.main_group.new_group('CorlexExample', 'CorlexExample')
sources = Dir.chdir(root) { Dir['CorlexExample/*.swift'].sort }
target.add_file_references(sources.map { |file| group.new_file(File.basename(file)) })
group.new_file('Info.plist')

# The SDK, from the package one folder up (a local reference; apps use the repository URL).
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '..'
project.root_object.package_references << package
dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dependency.product_name = 'Corlex'
target.package_product_dependencies << dependency
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = dependency
target.frameworks_build_phase.files << build_file

target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'ru.corlex.example'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SWIFT_VERSION'] = '5.0'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_FILE'] = 'CorlexExample/Info.plist'
  settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  settings['INFOPLIST_KEY_UISupportedInterfaceOrientations'] =
    'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  # The build phase below reads the dSYM folder and runs a script of the package, which the
  # sandbox for user scripts would forbid.
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['DEBUG_INFORMATION_FORMAT'] = config.name == 'Release' ? 'dwarf-with-dsym' : 'dwarf'
end

# Release builds upload the dSYM; without CORLEX_UPLOAD_TOKEN the script only prints a note.
phase = target.new_shell_script_build_phase('Upload symbols to Corlex')
phase.shell_script = <<~SCRIPT
  "${SRCROOT}/../scripts/upload-symbols.sh"
SCRIPT
phase.always_out_of_date = '1'

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(path, 'CorlexExample', true)
puts "wrote #{path}"
