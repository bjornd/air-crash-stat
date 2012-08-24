require 'csv'
require 'json'
require 'digest'
require 'net/http'
require 'nokogiri'

class CountryCodes
  @@file_name = 'coutry-codes.tsv'
  @@data = nil

  def self.load_data
    @@data = {}
    CSV.foreach(@@file_name, col_sep: "\t", encoding: "UTF-8") do |row|
      @@data[row[1]] = row[0]
    end
  end

  def self.get_code_by_name(name)
    CountryCodes.load_data unless @@data
    raise 'No coutry found: '+name unless @@data[name]
    return @@data[name]
  end
end

class Grabber
  @@accidents_url = 'http://aviation-safety.net/database/dblist.php?Year=%year%&page=%page%'
  @@accident_url = 'http://aviation-safety.net/database/record.php?id=%id%'
  @@accident_map_url = 'http://aviation-safety.net/database/record_map.php?id=%id%'

  def self.grab(url)
    puts url
    url_hash = Digest::MD5.hexdigest(url)
    response = nil
    if File.exist?('cache/'+url_hash)
      File.open('cache/'+url_hash, 'r:iso-8859-1') { |f| response = f.read }
    else
      response = Net::HTTP.get(URI.parse(URI.escape(url))).force_encoding('iso-8859-1');
      File.open('cache/'+url_hash, "w") { |f| f.write( response ) }
    end
    response
  end

  def self.grab_accidents(year, page = 1)
    Grabber.grab( @@accidents_url.sub('%year%', year.to_s).sub('%page%', page.to_s) )
  end

  def self.grab_accident(id)
    Grabber.grab( @@accident_url.sub('%id%', id) )
  end

  def self.grab_accident_map(id)
    Grabber.grab( @@accident_map_url.sub('%id%', id) )
  end
end

class Parser
  def self.parse_accidents(year)
    doc = Nokogiri::HTML(Grabber.grab_accidents(year))
    pager = doc.at_css('.pagenumbers')
    pages_number = 1
    if pager
      pages_number = pager.css('span, a').length
    end

    data = []
    (1..pages_number).each do |number|
      data.concat( Parser.parse_accidents_page(year, number) )
    end
    data
  end

  def self.parse_accidents_page(year, page)
    data = []
    doc = Nokogiri::HTML(Grabber.grab_accidents(year, page))
    doc.css('#contentcolumn table tr').each do |row|
      if row.css('td')[8] && row.css('td')[8].content == 'A1'
        id = row.css('td')[0].at_css('a').attribute('href').value.split('=').last
        accident_data = self.parse_accident(id)
        if accident_data
          data << accident_data
        end
      end
    end
    data
  end

  def self.parse_accident(id)
    data = {id: id}
    doc = Nokogiri::HTML(Grabber.grab_accident(id))
    doc.css('#contentcolumn table tr').each do |row|
      cells = row.css('td')
      if cells.length == 2
        case cells[0].content
        when 'Date:'
          data[:date] = Date.parse(cells[1].content)
        when 'Time:'
          data[:time] = cells[1].content
        when 'Type:'
          data[:type_id] = cells[1].css('a').attribute('href').value.split('=').last.to_i
        when 'Operator:'
          if cells[1].at_css('a')
            data[:operator_id] = cells[1].at_css('a').attribute('href').value.split('=').last.to_i
          else
            data[:operator_id] = nil
          end
        when 'First flight:'
          data[:first_flight] = cells[1].content.strip
        when 'Location:'
          data[:country_code] = CountryCodes.get_code_by_name(cells[1].at_css('a').content)
        when 'Airplane damage:'
          data[:damage] = cells[1].content.strip
        when 'Total:'
          match = /Fatalities: (\d+) \/ Occupants: (\d+)/.match(cells[1].content)
          if match
            data[:fatalities] = match[1].to_i
            data[:occupants] = match[2].to_i
          else
            return nil
          end
        end
      end
    end
    data[:location] = Parser.parse_accident_map(id)
    data
  end

  def self.parse_accident_map(id)
    match = /new GLatLng\((-?\d+.\d+), (-?\d+.\d+\))/.match(Grabber.grab_accident_map(id))
    if match
      return {latitude: match[1].to_f, longitude: match[2].to_f}
    else
      return nil
    end
  end
end

File.open('output.json', 'w') { |f| f.write( Parser.parse_accidents(2011).to_json ) }