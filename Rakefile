n = namespace :test do
  require 'rake/testtask'

  Rake::TestTask.new(:unit) do |t|
    t.pattern = 'test/unit/*_test.rb'
    t.verbose = false
    t.warning = false
  end

  Rake::TestTask.new(:smoke) do |t|
    t.pattern = 'test/smoke/*_test.rb'
    t.verbose = false
    t.warning = false
  end
end

task :test => [n[:unit], n[:smoke]]
task :default => :test

desc 'Import data from local drupal to Jekyll project'
task :import do
  require_relative 'lib/import.rb' 

  JekyllImport::Importers::Drupal6.run({
    'dbname'   => ENV['DBNAME'] || 'mst2',
    'user'     => ENV['USER'] || 'root',
    'password' => ENV['PASSWORD'] || 'root',
    'host'     => ENV['HOST'] || 'localhost',
    'prefix'   => ''
  })
end

