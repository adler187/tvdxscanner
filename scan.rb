#!/usr/bin/env ruby

require 'haversine'
require 'json'
require 'ffi-hdhomerun'
require 'open-uri'
require 'rest-client'

class ContinueException < Exception; end

class Scanner
  def initialize(config, server, username, password)
    @config = config
    @server = server
    @username = username
    @password = password
    
    begin
      @tuner = HDHomeRun::Tuner.new(:id => config['tuner_id'].to_s, :tuner => config['tuner_number'].to_i)
    rescue Exception => e
      puts "Caught exception #{e.class} at line #{__LINE__}"
      puts e
      
      return
    end
    
    @latitude = config['latitude'].to_f
    @longitude = config['longitude'].to_f
  end

  def scan
    # log all output from scan, note when calls and all-time new calls are found
    @scan_time = Time.now.strftime('%Y-%m-%d %T')
    
    begin
      @tuner.scan do |result|
        next if result.program_count <= 0
        
        begin
          puts "#{@config['name']} found station: #{program(result).name} with virtual channel #{program(result).major}. Using PSIP program number #{program(result).number}"
          
          station = get_station(result)
        
          log_entry = {
            :signal_strength => result.status.signal_strength,
            :signal_to_noise => result.status.signal_to_noise,
            :signal_quality => result.status.symbol_error_rate,
            :station_id => station['id'],
            :tuner_id => @config['id']
          }
          
          resource = RestClient::Resource.new("#{@server}/logs", :user => @username, :password => @password)
          response = resource.post({:log => log_entry}.to_json, :content_type => :json, :accept => :json)
          json = JSON.parse response
          
          if json['success']
            log_entry = json['log']
            puts "Created log ##{log_entry['id']}"
          else
            # TODO: print error here
          end
        rescue ContinueException => e
          next
        rescue Exception => e
          # TODO: Add proper logging here
          puts "Caught exception at #{Time.now}, #{e.class}: #{e}"
          puts station.class
          p station
          puts e.backtrace
          next
        end
      end
    rescue Exception => e
      puts "Caught exception at #{Time.now}, #{e.class}: #{e}"
      puts e.backtrace
    end
  end
  
private
  def program(result)
    result.programs[0]
  end
  
  def get_station(result)
    begin
      resource = RestClient::Resource.new("#{@server}/stations?tsid=#{result.tsid}&display=#{program(result).major}&rf=#{result.channel}", :user => @username, :password => @password)
      response = resource.get(:accept => :json)
    rescue => e
      puts "Caught exception #{e.class} at line #{__LINE__}"
    end
    
    json = JSON.parse response
    
    if json.length > 1
      raise ContinueException, "Invalid number of results for station: #{json.length}"
    elsif json.length == 0
      return new_station(result)
    else
      return json[0]['station']
    end
  end
  
  def new_station(result)
    if result.tsid == '0x0001'
      puts "Received a station with an invalid tsid #{result.tsid} on rf channel #{result.channel}, display channel #{program(result).major}, station IDs as #{program(result).name}, at #{@scan_time}"
      puts "This is most likely a translator that has not been properly set up correctly"
      puts "You can add this station manually, but note that the tsid might change in the future when it gets set properly and will be re-added"
      puts "Signal: #{result.status.signal_strength}, SNR: #{result.status.signal_to_noise}, SER: #{result.status.symbol_error_rate}"
      raise ContinueException, "Invalid tsid"
    end
    
    callsign = get_callsign(result)
    
    return if callsign.nil?
    
    distance, latitude, longitude = get_location(callsign, result)
    
    station = {
      :tsid => result.tsid,
      :callsign => callsign,
      :parent_callsign => nil,
      :rf => result.channel.to_i,
      :display => program(result).major.to_i,
      :latitude => latitude,
      :longitude => longitude,
      :distance => distance
    }
    
    resource = RestClient::Resource.new("#{@server}/stations", :user => @username, :password => @password)
    response = resource.post({:station => station}.to_json, :content_type => :json, :accept => :json)
    
    json = JSON.parse response
    
    if json['success']
      station = json['station']
    end
    puts "Created station ##{station['id']}"
    
    station
  end
  
  def get_callsign(result)
    callsign = program(result).name
    
    if(callsign.length > 4 && callsign.match(/\wDT$/))
      callsign = callsign[0, callsign.length-2]
    elsif callsign_match = callsign.match(/^((?:[CWKX][A-Z]{2,3})|(?:[KW]\d{1,2}[A-Z]{2}))/)
      callsign = callsign_match[1]
    else
      puts "getting callsign from rabbitears for tsid #{result.tsid}"
    end
    
    response = RestClient.get 'http://www.rabbitears.info/oddsandends.php?request=tsid'

    # TODO: log results for later

    if data_match = response.match(/<td>#{result.tsid}&nbsp;<\/td><td><a href=(?:'|")\/market\.php\?request=station_search&callsign=\d+(?:'|")>((?:[CWKX][A-Z]{2,3})|(?:[KW]\d{1,2}[A-Z]{2}))(?:-(?:(?:TV)|(?:DT)))?<\/a>&nbsp;<\/td><td align='right'>(\d+)(?:&nbsp;)*<\/td><td align='right'>(\d+)/)
      callsign = data_match[1]
      realdisp = data_match[2]
      realrf = data_match[3]

      unless(realrf == result.channel && realdisp.to_i == program(result).major.to_i)
        puts "Found a translator of #{callsign}(#{result.tsid}). IDs as #{program(result).name}, RF channel #{result.channel}, display channel #{program(result).major} at #{@scan_time}, add manually"
        puts "Signal: #{result.status.signal_strength}, SNR: #{result.status.signal_to_noise}, SER: #{result.status.symbol_error_rate}"
        raise ContinueException, "Found a translator, need to add manually"
      end
    else
      puts "Couldn't find callsign for tsid #{result.tsid} on channel #{result.channel}, display channel #{program(result).major}, station IDs as #{program(result).name}, at #{@scan_time}, add manually"
      puts "Signal: #{result.status.signal_strength}, SNR: #{result.status.signal_to_noise}, SER: #{result.status.symbol_error_rate}"
      raise ContinueException, "Unknown tsid"
    end
    
    callsign
  end
  
  def get_location(callsign, result)
    # facid: facility id number
    # call: callsign of station
    # chan: lower bound on channel number to search
    # cha2: upper bound on channel number to search
    # type: (3) Only licenced stations, no CPs or pending aps
    # list: (4) Text ouput, pipe delimited
    response = RestClient.get "http://www.fcc.gov/fcc-bin/tvq?call=#{callsign}&chan=#{result.channel}&cha2=#{result.channel}&list=4"
    # TODO: log results for later
    
    lines = response.strip.split("\n")
    
    if lines.length == 0
      puts "Found a translator of callsign on channel #{result.channel} at #{@scan_time}, add manually"
      puts "Signal: #{result.status.signal_strength}, SNR: #{result.status.signal_to_noise}, SER: #{result.status.symbol_error_rate}"
      raise ContinueException, "Found a translator"
    end

    latitude = longitude = distance = nil
    
    lines.each do |line|
      tokens = line.split('|')
      tokens.each_index do |i|
        tokens[i] = tokens[i].strip
      end

      unused,
      call,
      unused,
      lic_type,
      chan,
      app_type,
      unused,
      tv_zone,
      unused,
      antenna_type,
      city,
      state,
      country,
      fileno,
      erp,
      unused,
      haat,
      unused,
      facid,
      lat,
      lat_deg,
      lat_min,
      lat_sec,
      long,
      long_deg,
      long_min,
      long_sec,
      licencee,
      km,
      mi,
      azimuth,
      amsl,
      polarization,
      antenna_id,
      rotation,
      asrn,
      agl = tokens

      if lic_type.match(/STA/)
        next
      end
      
      latitude = (lat_deg.to_f + lat_min.to_f/60 + lat_sec.to_f/3600) * (lat == 'S' ? -1 : 1)
      longitude = (long_deg.to_f + long_min.to_f/60 + long_sec.to_f/3600) * (long == 'W' ? -1 : 1)

      distance = Haversine.distance(@latitude, @longitude, latitude, longitude).to_miles

      if lic_type.match(/LIC/)
        break
      end
    end
    
    return [distance, latitude, longitude]
  end
end

if ARGV.length != 3
  puts "scan.rb [URL] [username] [password]"
  exit 1
end

server = ARGV[0]
username = ARGV[1]
password = ARGV[2]


default_config = {
  'scan_interval' => 10
}

threads = []
HDHomeRun.discover.each do |tuner|
  tuner[:tuner_count].times do |i|
    begin
      url = "#{server}/tuners/#{tuner[:id]}/#{i}"
      resource = RestClient::Resource.new(url, :user => username, :password => password)
      response = resource.get(:accept => :json)
    rescue => e
      next
    end
    
    tuner_info = default_config.merge(JSON.parse(response))
    
    if tuner_info['info'].is_a? Hash
      info = tuner_info['info']
      tuner_info.delete 'info'
      tuner_info = info.merge(tuner_info)
      
      tuner_info['latitude'] = tuner_info['lattitude']
      tuner_info.delete 'lattitude'
    end
    
    threads << Thread.new(tuner_info) do |tuner_info|
      scanner = Scanner.new(tuner_info, server, username, password)
      while true
        scan_interval = tuner_info['scan_interval'].to_i * 60
        
        scanner.scan
        sleep scan_interval
      end
    end
  end
end
# 
threads.each do |thread|
  thread.join
end
