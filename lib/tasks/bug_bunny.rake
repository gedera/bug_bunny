# frozen_string_literal: true

require 'date'

namespace :bug_bunny do
  desc 'Sync BugBunny AI docs reference in CLAUDE.md with the installed version'
  task :sync do
    spec = Gem::Specification.find_by_name('bug_bunny')
    version = spec.version.to_s
    docs_path = File.join(spec.gem_dir, 'docs', 'ai')
    claude_md_path = File.join(Dir.pwd, 'CLAUDE.md')

    content = if File.exist?(claude_md_path)
                File.read(claude_md_path)
              else
                app_name = File.basename(Dir.pwd).split(/[-_]/).map(&:capitalize).join
                puts 'bug_bunny:sync — CLAUDE.md not found, creating it.'
                "# #{app_name}\n"
              end

    # Idempotent: same version already present, nothing to do
    if content.include?('### bug_bunny') && content.include?("**Version:** #{version}")
      puts "bug_bunny:sync — already at #{version}, nothing to do."
      next
    end

    block = <<~BLOCK
      ### bug_bunny
      - **Version:** #{version}
      - **Docs:** #{docs_path}
      - **Updated:** #{Date.today}
    BLOCK

    # Replace existing block if present
    if content.match?(/^### bug_bunny\n/)
      updated = content.gsub(/^### bug_bunny\n(?:- \*\*.*\n)*/, block)
      File.write(claude_md_path, updated)
      puts "bug_bunny:sync — updated to #{version} in CLAUDE.md"
    elsif content.include?('## Gemas internas')
      # Append under existing section
      updated = content.sub(/^## Gemas internas\n/, "## Gemas internas\n\n#{block}")
      File.write(claude_md_path, updated)
      puts "bug_bunny:sync — added #{version} under '## Gemas internas' in CLAUDE.md"
    else
      # Create section at end of file
      File.write(claude_md_path, content.rstrip + "\n\n## Gemas internas\n\n#{block}")
      puts "bug_bunny:sync — added '## Gemas internas' section with #{version} to CLAUDE.md"
    end
  end
end
