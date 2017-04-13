task :default => [:'docs:generate']

namespace :docs do

  desc 'Generate documentation'
  task :generate => [:'docs:clean'] do
    appledoc_options = [
      '--output Documentation',
      '--project-name FirebaseParcelKit',
      '--project-company \'Andy Geers based on Overcommitted, LLC\'',
      '--company-id net.geero',
      '--keep-intermediate-files',
      '--create-html',
      '--no-repeat-first-par',
      '--no-create-docset',
      '--no-merge-categories',
      '--verbose 3']

    puts `appledoc #{appledoc_options.join(' ')} ParcelKit/*.h`
  end

  desc 'Clean docs'
  task :clean do
    `rm -rf Documentation/*`
  end

end
