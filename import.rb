require 'fileutils'
require 'nokogiri'
require 'yaml'
require 'erb'

# based in part on https://gist.github.com/juniorz/1564581

# usage: ruby import.rb annotated-teifacsimile.xml

TEI_NAMESPACE = "http://www.tei-c.org/ns/1.0"
$TEI_NS = {'t' => TEI_NAMESPACE}


class XmlObject
    def initialize(xmlelement)
        @el = xmlelement
    end

    def xpath_ns
        {}
    end

    def convert_el(el, opts = {})
        if opts[:as]
            opts[:as].new(el)
        else
            if defined? el.content
                content = el.content
            else
                content = el
            end

            if opts[:type] == Integer
                content.to_i
            elsif opts[:type] == Float
                content.to_f
            else
                content
            end
        end
    end

    def self.xml_attr_reader(attr_name, opts = {})
        attr_name = attr_name.to_s
        define_method(attr_name) do
            els = @el.xpath(opts[:xpath], self.xpath_ns)
            if opts[:list]
                content = []
                els.each do |el|
                    content << self.convert_el(el, opts)
                end
                return content
            elsif opts[:hash] and opts[:hash_key_xpath]
                content = {}
                els.each do |el|
                    hash_key = self.convert_el(el.at_xpath(opts[:hash_key_xpath]))
                    content[hash_key] =self.convert_el(el, opts)
                end
                return content
            else
                # some xpaths return a list, but others
                # (like count) just return a value;
                # handling here to avoid complication with hash key results
                # in convert_el method
                if defined? els.first
                    el = els.first()
                else
                    el = els
                end
                self.convert_el(el, opts)
            end
        end
    end

end

class TeiXmlObject < XmlObject
    def xpath_ns
        $TEI_NS
    end
end

class TeiTitleStatement < TeiXmlObject
    xml_attr_reader :title, :xpath => './/t:title[@type="main"]'
    xml_attr_reader :subtitle, :xpath => './/t:title[@type="sub"]'
end

class TeiRef < TeiXmlObject
    xml_attr_reader :type, :xpath => '@type'
    xml_attr_reader :target, :xpath => '@target'
end

class TeiBibl < TeiXmlObject
    xml_attr_reader :type, :xpath => '@type'
    xml_attr_reader :title, :xpath => 't:title'
    xml_attr_reader :date, :xpath => 't:date'
    xml_attr_reader :author, :xpath => 't:author'
    xml_attr_reader :references, :xpath => 't:ref', :as => TeiRef, :hash => true,
        :hash_key_xpath => '@type'
end

class TeiGraphic < TeiXmlObject
    xml_attr_reader :rend, :xpath => '@rend'
    xml_attr_reader :url, :xpath => '@url'
end

class TeiZone < TeiXmlObject
    xml_attr_reader :id, :xpath => '@xml:id'
    xml_attr_reader :n, :xpath => '@n'
    xml_attr_reader :type, :xpath => '@type'
    xml_attr_reader :ulx, :xpath => '@ulx', :type => Float
    xml_attr_reader :uly, :xpath => '@uly', :type => Float
    xml_attr_reader :lrx, :xpath => '@lrx', :type => Float
    xml_attr_reader :lry, :xpath => '@lry', :type => Float
    xml_attr_reader :href, :xpath => '@xlink:href'  # maybe not needed?
    xml_attr_reader :text, :xpath => 't:line|t:w'
    xml_attr_reader :word_zones, :xpath => './/t:zone[@type="string"]',
        :as => TeiZone, :list => true

    #: nearest ancestor zone
    xml_attr_reader :parent, :xpath => 'ancestor::t:zone[1]', :as => TeiZone
    #: containing page
    xml_attr_reader :page, :xpath => 'ancestor::t:surface[@type="page"]',
        :as => TeiZone
    # # not exactly a zone, but same attributes we care about (type, id, ulx/y, lrx/y)

    def width
        self.lrx - self.ulx
    end

    def height
        self.lry - self.uly
    end

    def avg_height
        '''Calculated average height of word zones in the current zone
        (i.e. in a text line)'''
        unless self.word_zones.empty?
            word_heights = []
            self.word_zones.each do |w|
                word_heights << w.height
            end
            return word_heights.inject{ |sum, el| sum + el }.to_f / word_heights.size
        end
    end

    def long_edge
        # return the size of the longer edge of this zone
        [self.width, self.height].max
    end

    SINGLE_PAGE_SIZE = 1000
    # FIXME: should be configured somewhere
    # (we happen to know this is current readux full page size...)

    def zone_style()
        # generate html style and data attributes to position
        # the ocr text based on coordinates in the TEI
        # (logic adapted from readux)
        styles = {}
        data = {}
        # determine scale from original page size to current display size,
        # for non-relative styles (i.e. font sizes)
        scale = SINGLE_PAGE_SIZE.to_f / self.page.long_edge.to_f

        def percent(a, b)
            # a as percentage of b
            # ensure both are cast to float, divide, then multiply by 100
            return (a.to_f / b.to_f) * 100
        end

        if ['textLine', 'line'].include? self.type
            # text lines are absolutely positioned boxes
            styles['left'] = '%.2f%%' % percent(self.ulx, self.page.width)
            styles['top'] = '%.2f%%' % percent(self.uly, self.page.height)

            # width relative to page size
            styles['width'] = '%.2f%%' % percent(self.width, self.page.width)
            styles['height'] = '%.2f%%' % percent(self.height, self.page.height)

            # TODO: figure out how to determine this from ocr/teifacsimile
            # rather than assuming
            styles['text-align'] = 'left'

            # set pixel-based font size for browsers that don't support viewport based sizes.
            # for mets-alto, use average height of words in the line to calculate font size
            # for abbyy ocr, no word zones exist, so just use line height
            styles['font-size'] = '%.2fpx' % ((self.avg_height || self.height) * scale)

            # calculate font size as percentage of page height;
            # this will be used by javascript to calculate as % of viewport height
            data['vhfontsize'] = '%.2f' % percent(self.lry - self.uly, self.page.height)

        elsif self.type == 'string'
            # set width & height relative to *parent* line, not the whole page
            styles['width'] = '%.2f%%' % percent(self.width, self.parent.width)
            styles['height'] = '%.2f%%' % percent(self.height, self.parent.height)

            # position words absolutely within the line
            styles['left'] = '%.2f%%' % percent(self.ulx - self.parent.ulx, self.parent.width)

        elsif self.type == 'image-annotation-highlight'
            # image annotation zone; similar to line logic, but without font calculations

            # image highlights are absolutely positioned boxes
            styles['left'] = '%.2f%%' % percent(self.ulx, self.page.width)
            styles['top'] = '%.2f%%' % percent(self.uly, self.page.height)

            # size relative to page size
            styles['width'] = '%.2f%%' % percent(self.width, self.page.width)
            styles['height'] = '%.2f%%' % percent(self.height, self.page.height)

        end

        # construct html style and data attribute string
        attrs = ''
        unless styles.empty?
            attrs += 'style="%s"' % styles.map { |k, v| "#{k}:#{v}"}.join(';')
        end
        unless data.empty?
            attrs += ' ' + data.map { |k, v | "data-#{k}='#{v}'"}.join(' ')
        end

        return attrs
    end

    def annotation_id
        if self.type == 'image-annotation-highlight'
            self.id.gsub(/^highlight-/, '')
        end
    end

end

class TeiFacsimilePage < TeiXmlObject
    xml_attr_reader :id, :xpath => '@xml:id'
    xml_attr_reader :n, :xpath => '@n'

    xml_attr_reader :images, :xpath => 't:graphic', :list => true,
        :as => TeiGraphic

    xml_attr_reader :annotation_count, :type => Integer,
        :xpath => 'count(.//t:anchor[@type="text-annotation-highlight-start"]
            |.//t:zone[@type="image-annotation-highlight"])'

    xml_attr_reader :lines, :xpath => './/t:zone[@type="textLine" or @type="line"]',
        :as => TeiZone, :list => true

    xml_attr_reader :word_zones, :xpath => './/t:zone[@type="string"]',
        :as => TeiZone, :list => true

    xml_attr_reader :image_highlight_zones, :xpath => 't:zone[@type="image-annotation-highlight"]',
        :as => TeiZone, :list => true

    def template()
        # template to position ocr text over the image
        # - logic adapted from readux
        %{
        <% for line in self.lines %>
        <div class="ocr-line <% if line.word_zones.empty? %>ocrtext<% end %>" <% if line.id %>id="<%= line.id %>"<% end %>
            <%= line.zone_style %>>
            <% for zone in line.word_zones %>
            <div class="ocr-zone ocrtext" <%= zone.zone_style %>>
               <span><%= zone.text %></span>
            </div>
            <% end %>
            <% if line.word_zones.empty? %>
                <span><%= line.text %></span>
            <% end %>
        </div>
        <% end %>
        <% for img_highlight in self.image_highlight_zones %>
            <span class="annotator-hl image-annotation-highlight"
                data-annotation-id="<%= img_highlight.annotation_id %>"
                <%= img_highlight.zone_style %>>
            </span>
        <% end %>
      }
    end

    def html()
        return ERB.new(self.template()).result(binding)
    end

end

class TeiNote < TeiXmlObject
    attr_accessor :start_target, :end_target
    xml_attr_reader :id, :xpath => '@xml:id'
    xml_attr_reader :author, :xpath => '@resp'
    xml_attr_reader :target, :xpath => '@target'
    xml_attr_reader :markdown, :xpath => './/t:code[@lang="markdown"]'

    def range_target?
        return self.target.start_with?('#range')
    end

    def annotated_page
        # find the page that is annotated by this note
        if self.range_target?
            # text selections are stored in tei like
            # #range(#start_id, #end_id)
            target = self.target.gsub(/(^#range\(|\)$)/, '')
            @start_target, @end_target = target.split(', ')
            @start_target.gsub!(/^#/, '')
            @end_target.gsub!(/^#/, '')
        else
            # target ref format is #id; strip out # to get xml:id
            @start_target = self.target.gsub(/^#/, '')
        end

        # find the page that contains the annotation reference
        @annotated_page = TeiFacsimilePage.new(@el.at_xpath('//t:surface[@type="page"][.//*[@xml:id="%s"]]' % @start_target, $TEI_NS))

        return @annotated_page
    end

    def annotation_id
        self.id.gsub(/^annotation-/, '')
    end

end

class TeiFacsimile < TeiXmlObject
    xml_attr_reader :title_statement, :xpath => '//t:teiHeader/t:fileDesc/t:titleStmt',
        :as => TeiTitleStatement

    xml_attr_reader :title, :xpath => '//t:teiHeader/t:fileDesc/t:titleStmt/t:title[@type="full"]/t:title[@type="main"]'
    xml_attr_reader :subtitle, :xpath => '//t:teiHeader/t:fileDesc/t:titleStmt/t:title[@type="full"]/t:title[@type="sub"]'

    xml_attr_reader :source_bibl, :xpath => '//t:teiHeader/t:fileDesc/t:sourceDesc/t:bibl',
        :as => TeiBibl, :hash => true, :hash_key_xpath => '@type'

    xml_attr_reader :pages, :xpath => '//t:facsimile/t:surface[@type="page"]',
        :as => TeiFacsimilePage, :list => true

    xml_attr_reader :annotations, :xpath => '//t:note[@type="annotation"]',
        :as => TeiNote, :list => true

end

teixml = File.open(ARGV[0]) { |f| Nokogiri::XML(f) }
teidoc = TeiFacsimile.new(teixml)

$volume_page_dir = '_volume_pages'
$annotation_dir = '_annotations'


def output_page(teipage)
    puts "Page #{teipage.n}"
    path = File.join($volume_page_dir, "%04d.html" % teipage.n.to_i)
    # retrieve page graphic urls by type for inclusion in front matter
    images = {}  # hash of image urls by rend attribute
    teipage.images.each { |img| images[img.rend] = img.url }
    # construct page front matter
    front_matter = {
        'title'=> 'Page %s' % teipage.n,
        'page_order'=> teipage.n.to_i,
        'tei_id' => teipage.id,
        'annotation_count' => teipage.annotation_count,
        'images' => images
    }

    File.open(path, 'w') do |file|
        # write out front matter as yaml
        file.write front_matter.to_yaml
        file.write  "\n---"
        # todo: unique page content that can't be handled by template
        # (should be primarily tei text and annotation references)
        # file.write "\n<img src='#{images["page"]}' />"
        file.write teipage.html()
    end
end

def output_annotation(teinote)
    puts "Annotation #{teinote.id}"
    path = File.join($annotation_dir, "%s.md" % teinote.id)
    front_matter = {
        'annotation_id' => teinote.annotation_id,
        'author' => teinote.author,
        'tei_target' => teinote.target,
        'annotated_page' => teinote.annotated_page.id,
        'target' => teinote.start_target
    }
    if teinote.range_target?
        front_matter['end_target'] = teinote.end_target
    end

    File.open(path, 'w') do |file|
        # write out front matter as yaml
        file.write front_matter.to_yaml
        file.write  "\n---\n"
        # annotation content
        file.write teinote.markdown

    end

end

# generate a volume page document for every facsimile page in the TEI
puts "** Writing volume pages"
FileUtils.rm_rf($volume_page_dir)
Dir.mkdir($volume_page_dir) unless File.directory?($volume_page_dir)
teidoc.pages.each do |teipage|
    output_page(teipage)
end

# generate an annotation document for every annotation in the TEI
puts "** Writing annotations"
FileUtils.rm_rf($annotation_dir)
Dir.mkdir($annotation_dir) unless File.directory?($annotation_dir)

teidoc.annotations.each do |teinote|
    output_annotation(teinote)
end


puts '** Updating site config'
if File.exist?('_config.yml')
    siteconfig = YAML.load_file('_config.yml')

    # set site title and subtitle from the tei
    siteconfig['title'] = teidoc.title_statement.title
    siteconfig['tagline'] = teidoc.title_statement.subtitle

    # placeholder description for author to edit (todo: include annotation author name here?)
    siteconfig['description'] = 'An annotated digital edition created with <a href="http://readux.library.emory.edu/">Readux</a>'

    # add urls to readux volume and pdf
    siteconfig['readux_url'] = teidoc.source_bibl['digital'].references['digital-edition'].target
    siteconfig['readux_pdf_url'] = teidoc.source_bibl['digital'].references['pdf'].target

    # add original publication information
    original = teidoc.source_bibl['original']
    pubinfo = {'title' => original.title, 'author' => original.author,
        'date' => original.date}

    # configure collections specific to tei facsimile + annotation data
    siteconfig.merge!({
        'publication_info' => pubinfo,
        'collections' => {
            # NOTE: annotations *must* come first, so content can
            # be rendered for display in volume pages templates
            'annotations' => {
                'output' => false
            },
            'volume_pages' => {
                'output' => true,
                'permalink' => '/pages/:path/'
            },
        },
        'defaults' => {
           'scope' => {
                'path' => '',
                'type' => 'volume_pages',
            },
            'values' => {
                'layout' => 'volume_pages'
            }
          }
    })
    # TODO:
    # - author information from resp statement?

    File.open('_config.yml', 'w') do |file|
        # write out updated site config
        file.write siteconfig.to_yaml
    end
end

