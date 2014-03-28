# encoding: utf-8
require "mysql"
require "jekyll-import"
require "open-uri"
require_relative "html2markdown_monkeypatch"

# monkey patching the drupal 6 importer
# adding more metadatas ( tags and images ) do each post
module JekyllImport
  module Importers
    class Drupal6 < Importer
      REFRESH_HTML = "\
        <!DOCTYPE html> \
          <html> \
            <head> \
            <meta http-equiv=\"content-type\" content=\"text/html; charset=utf-8\" /> \
            <meta http-equiv=\"refresh\" content=\"0;url={{ page.refresh_to_post_id }}.html\" /> \
          </head>
        </html>"
        
      QUERY = " (SELECT  n.nid, \ 
                         n.title, \
                         nr.body,\
                         n.created, \
                         n.status, \
                         GROUP_CONCAT( CONCAT(v.name,':', tags.name) SEPARATOR '|' ) as 'tags', \
                         GROUP_CONCAT( CONCAT(f.filepath) SEPARATOR '|' ) as 'images', \
                         'video' as type
                 FROM  node as n \
                       INNER JOIN node_revisions as nr ON (n.vid = nr.vid) \
                       LEFT OUTER JOIN term_node as tn ON tn.nid = n.nid  \
                       LEFT OUTER JOIN term_data as tags on tn.tid = tags.tid  \
                       LEFT OUTER JOIN vocabulary as v on v.vid = tags.vid \
                       LEFT OUTER JOIN upload as u on u.nid =n.nid \
                       LEFT OUTER JOIN files AS f on f.fid = u.fid \
                 WHERE tn.tid in (336, 382, 347) \
                       AND (f.status = 1 OR f.status is null) \
                       AND (u.list = 1 OR u.list is null) \
                       AND nr.body LIKE '%youtube.com/v/%' \
                GROUP BY n.nid \
                ORDER BY created DESC \
                LIMIT 3)
                UNION
                (SELECT   n.nid, \ 
                         n.title, \
                         nr.body,\
                         n.created, \
                         n.status, \
                         GROUP_CONCAT( CONCAT(v.name,':', tags.name) SEPARATOR '|' ) as 'tags', \
                         GROUP_CONCAT( CONCAT(f.filepath) SEPARATOR '|' ) as 'images', \
                         'news' as type
                 FROM  node as n \
                       INNER JOIN node_revisions as nr ON (n.vid = nr.vid) \
                       LEFT OUTER JOIN term_node as tn ON tn.nid = n.nid  \
                       LEFT OUTER JOIN term_data as tags on tn.tid = tags.tid  \
                       LEFT OUTER JOIN vocabulary as v on v.vid = tags.vid \
                       LEFT OUTER JOIN upload as u on u.nid =n.nid \
                       LEFT OUTER JOIN files AS f on f.fid = u.fid \
                 WHERE tn.tid in (336, 382, 347) \
                       AND (f.status = 1 OR f.status is null) \
                       AND (u.list = 1 OR u.list is null) \
                       AND nr.body NOT LIKE '%youtube.com/v/%' \
                GROUP BY n.nid \
                ORDER BY created DESC \
                LIMIT 3);" 

      def self.require_deps
        JekyllImport.require_with_fallback(%w[
          rubygems
          sequel
          fileutils
          safe_yaml
        ])
      end

      def self.post_tags(post)
        pairs = post[:tags].to_s.split("|")
        tags  = pairs.collect_concat do |pair|
          pair.force_encoding("UTF-8").split(":")
        end

        Hash[*tags]
      end

      def self.post_images(post)
        images = post[:images].to_s.split("|") || []
        images.reduce([]) do |collection, img|
          puts "post_images: #{img}"
          url = absolute_url img.force_encoding("UTF-8")
          img.downcase.scan(/\.jpg/).empty? ? collection : collection << url
        end
      end

      def self.content_images(markdown)
        regex = /(!\[.*?\]\(.+?\))/
        match = markdown.match(regex)
        (match ? match.captures : []).map do |img|
          puts "content_images: #{URI.decode img}"
          absolute_url URI.decode(img.gsub(/[!\[\]\(\)]/,""))
        end
      end

      def self.absolute_url(path)
        "http://mst.org.br:#{path}" if path.start_with?("/")
      end

      def self.youtube_video(content)
        regex = /"(http:\/\/www.youtube.com\/\S+)"/
        match = content.match(regex)
        url = match.captures.first.gsub(/#.*/, '') if match
        "#{url}" if url
      end

      def self.markdonify(content)
        content = content.force_encoding("UTF-8")
        content.gsub!(/\*/, '\\*')
        content.gsub!(/\#/, '\\#')
        content.gsub!(/[`´]/, '"')

        page = HTMLPage.new(:contents => content)
        page.markdown.force_encoding("UTF-8")
      end

      def self.process(options)
        dbname = options.fetch('dbname')
        user   = options.fetch('user')
        pass   = options.fetch('password', "")
        host   = options.fetch('host', "localhost")
        prefix = options.fetch('prefix', "")

        db = Sequel.mysql(dbname, :user => user, :password => pass, :host => host, :encoding => 'utf8')

        if prefix != ''
          QUERY[" node "] = " " + prefix + "node "
          QUERY[" node_revisions "] = " " + prefix + "node_revisions "
          QUERY[" term_node "] = " " + prefix + "term_node "
          QUERY[" term_data "] = " " + prefix + "term_data "
        end
        
        FileUtils.remove_dir "_posts"        
        
        FileUtils.mkdir_p "_posts"
        FileUtils.mkdir_p "_drafts"
        FileUtils.mkdir_p "_layouts"

        # Create the refresh layout
        # Change the refresh url if you customized your permalink config
        File.open("_layouts/refresh.html", "w") do |f|
          f.puts REFRESH_HTML
        end

        db[QUERY].each do |post|

          # Get required fields and construct Jekyll compatible name
          node_id = post[:nid]
          title = post[:title].gsub(/"/, '')
          content = post[:body]
          content_markdown = markdonify(content)
          tags = post_tags(post)
          images = post_images(post) + content_images(content_markdown)
          
          type = post[:type]
          video = (type == 'video' ? youtube_video(content) : "")
          
          created = post[:created]
          time = Time.at(created)
          is_published = post[:status] == 1
          dir = is_published ? "_posts" : "_drafts"
          slug = title.strip.downcase.gsub(/(&|&amp;)/, ' and ').gsub(/[\s\.\/\\]/, '-').gsub(/[^\w-]/, '').gsub(/[-_]{2,}/, '-').gsub(/^[-_]/, '').gsub(/[-_]$/, '')
          name = time.strftime("%Y-%m-%d-") + slug + '.md'

          # Get the relevant fields as a hash, delete empty fields and convert
          # to YAML for the header
          data = {
            'layout' => 'post',
            'title' => title.to_s,
            'legacy_url' => "http://www.mst.org.br/node/#{node_id}",
            'created' => created,
            'images' => images,
            'video' => video,
            'tags' => tags.values +  (type ? [type] : [])
          }.each_pair {
            |k,v| ((v.is_a? String) ? v.force_encoding("UTF-8") : v)
          }

          puts "importing: #{post[:title]}"


          # Write out the data and content to file
          File.open("#{dir}/#{name}", "w") do |f|
            f.puts data.merge(tags).to_yaml()
            f.puts "---"
            f.puts content_markdown
          end

          # Make a file to redirect from the old Drupal URL
          if is_published
            aliases = db["SELECT CONCAT('_pages/',dst) as dst FROM #{prefix}url_alias WHERE src = ?", "node/#{node_id}"].all

            aliases.push(:dst => "_pages/node/#{node_id}")

            aliases.each do |url_alias|
              FileUtils.mkdir_p url_alias[:dst]
              File.open("#{url_alias[:dst]}/index.md", "w") do |f|
                f.puts "---"
                f.puts "layout: refresh"
                f.puts "refresh_to_post_id: /mst/#{time.strftime("%Y/%m/%d/") + slug}"
                f.puts "---"
              end
            end
          end
        end

        # TODO: Make dirs & files for nodes of type 'page'
        # Make refresh pages for these as well
      end
    end
  end
end

