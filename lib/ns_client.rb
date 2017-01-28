#encoding: utf-8
require 'pathname'
require 'time'
require 'nori'
require 'nokogiri'

require 'httpclient'

require "addressable/uri"

this = Pathname.new(__FILE__).realpath
lib_path = File.expand_path("..", this)
$:.unshift(lib_path)

$ROOT = File.expand_path("../", lib_path)

Dir.glob(File.join(lib_path, '/**/*.rb')).each do |file|
  require file
end

module NSYapi

  class Configuration
    attr_accessor :username, :password
  end

  def self.configure(configuration = NSYapi::Configuration.new)
    yield configuration if block_given?
    @@configuration = configuration
  end

  def self.configuration # :nodoc:
    @@configuration ||= NSYapi::Configuration.new
  end

  def self.client
    @client_instance = NSClient.new(configuration.username, configuration.password) unless @client_instance
    @client_instance
  end

end

class NSClient

  attr_accessor :last_received_raw_xml, :last_received_corrected_xml

  def initialize(username, password)
    @client = HTTPClient.new
    @client.set_auth("http://webservices.ns.nl", username, password)
    @prices_url = PricesUrl.new("http://webservices.ns.nl/ns-api-prijzen-v3")
    @trip_url = TripUrl.new("http://webservices.ns.nl/ns-api-treinplanner")
    @last_received_raw_xml = ""
    @last_received_corrected_xml = ""
  end

  def stations
    parse_stations(get_xml("http://webservices.ns.nl/ns-api-stations-v2"))
  end

  def stations_short
    parse_stations_as_map(get_xml("http://webservices.ns.nl/ns-api-stations-v2"))
  end

  def disruptions (query = nil)
    response_xml = get_xml(disruption_url(query))
    raise_error_when_response_is_error(response_xml)
    parse_disruptions(response_xml)
  end

  def trips (opts = {fromStation: nil, toStation: nil, via: nil, date: nil})
    raise MissingParameter, "from and to station is required" if (opts[:fromStation] == nil && opts[:toStation] == nil)
    raise MissingParameter, "from station is required" unless opts[:fromStation]
    raise MissingParameter, "to station is required" unless opts[:toStation]
    response_xml = get_xml(@trip_url.url(opts))
    raise_error_when_response_is_error(response_xml)
    parse_trips(response_xml)
  end

  def parse_trips(response_xml)
    trips_response = TripsResponse.new
    trips =[]
    routes =[]

    (response_xml/'/ReisMogelijkheden/ReisMogelijkheid').each do |trip_xml|
      trip = Trip.new
      trip_stops = []

      (trip_xml/'ReisDeel').each do |reisdeel_xml|
        reisdeel = ReisDeel.new
        reisdeel.soort = reisdeel_xml.attr("reisSoort")
        deel_stops = []
        deel_stops = (reisdeel_xml/'ReisStop').collect {|s| s.xpath("Naam").text;}
        if not deel_stops.blank?
          reisdeel.stops = deel_stops
          trip_stops |= deel_stops
        end
        trip.reisdeels << reisdeel
      end
      trip.stops = trip_stops
      routes << trip_stops

      trips << trip
    end
    trips_response.trips = trips
    trips_response.routes = routes.uniq
    trips_response
  end

  def prices (opts = {from: nil, to: nil, via: nil, date: nil})
    raise MissingParameter, "from and to station is required" if (opts[:from] == nil && opts[:to] == nil)
    raise MissingParameter, "from station is required" unless opts[:from]
    raise MissingParameter, "to station is required" unless opts[:to]
    response_xml = get_xml(@prices_url.url(opts))
    raise_error_when_response_is_error(response_xml)
    parse_prices(response_xml)
  end

  def parse_prices(response_xml)
    enkele_price = response_xml.xpath('//ReisType[@name="Enkele reis"]/ReisKlasse[@klasse="2"]/Korting/Kortingsprijs[@name="vol tarief"]').attr("prijs").value
    retour_price = response_xml.xpath('//ReisType[@name="Retour"]/ReisKlasse[@klasse="2"]/Korting/Kortingsprijs[@name="vol tarief"]').attr("prijs").value

    prices_response = PricesResponse.new
 
    name = "Enkele reis"
    price = ProductPrice.new
    price.type = name
    price.train_class = "2"
    price.amount = enkele_price
    
    prices_response.tariffs[name] = price

    name = "Retour"
    price = ProductPrice.new
    price.type = name
    price.train_class = "2"
    price.amount = retour_price
    
    prices_response.tariffs[name] = price

    prices_response
  end

  def parse_stations(response_xml)
    result = []
    (response_xml/'/Stations/Station').each do |station|
      s = Station.new
      s.code = (station/'./Code').text
      s.type = (station/'./Type').text
      s.country = (station/'./Land').text
      s.short_name = (station/'./Namen/Kort').text
      s.name = (station/'./Namen/Middel').text
      s.long_name = (station/'./Namen/Lang').text
      s.lat = (station/'./Lat').text
      s.long = (station/'./Lon').text
      s.uiccode = (station/'./UICCode').text
      result << s
    end
    result
  end

  def parse_stations_as_map(response_xml)
    result = {}
    (response_xml/'/Stations/Station').each do |station|
      code = (station/'./Code').text
      name = (station/'./Namen/Middel').text
      country = (station/'./Land').text
      result[code] = [name, country]
    end
    result
  end

  def parse_disruptions(response_xml)
    result = {planned: [], unplanned: []}
    (response_xml/'/Storingen').each do |disruption|
      (disruption/'Ongepland/Storing').each do |unplanned|
        unplanned_disruption = UnplannedDisruption.new
        unplanned_disruption.id = (unplanned/'./id').text
        unplanned_disruption.trip = (unplanned/'./Traject').text
        unplanned_disruption.reason = (unplanned/'./Reden').text
        unplanned_disruption.message = (unplanned/'./Bericht').text
        unplanned_disruption.datetime_string = (unplanned/'./Datum').text
        unplanned_disruption.cause = (unplanned/'./Oorzaak').text
        result[:unplanned] << unplanned_disruption
      end

      (disruption/'Gepland/Storing').each do |planned|
        planned_disruption = PlannedDisruption.new
        planned_disruption.id = (planned/'./id').text
        planned_disruption.trip = (planned/'./Traject').text
        planned_disruption.reason = (planned/'./Reden').text
        planned_disruption.advice = (planned/'./Advies').text
        planned_disruption.message = (planned/'./Bericht').text
        planned_disruption.cause = (planned/'./Oorzaak').text
        result[:planned] << planned_disruption
      end
    end
    result
  end

  def raise_error_when_response_is_error(xdoc)
    (xdoc/'/error').each do |error|
      message = (error/'./message').text
      raise InvalidStationNameError, message
    end
  end

  def get_xml(url)
    response = @client.get url
    @last_received_raw_xml = response.content
    @last_received_corrected_xml = remove_unwanted_whitespace(@last_received_raw_xml)
    begin
      Nokogiri.XML(@last_received_corrected_xml) do |config|
        config.options = Nokogiri::XML::ParseOptions::STRICT
      end
    rescue Nokogiri::XML::SyntaxError => e
      raise UnparseableXMLError.new e
    end

  end

  def remove_unwanted_whitespace content
    content.gsub /<\s*(\/?)\s*?([a-zA-Z0-9]*)\s*([a-zA-Z0-9]*)\s*>/, '<\1\2\3>'
  end

  def disruption_url(query)
    return "http://webservices.ns.nl/ns-api-storingen?station=#{query}" if query
    "http://webservices.ns.nl/ns-api-storingen?actual=true"
  end

  class TripsResponse
    # Response --> Trips --> ReisDeels
    # @stops 来自ReisDeels 中包含最多stops 的deel
    attr_accessor :trips, :routes

    def initialize
      @trips = []
      @routes = []
    end

    def check
      self.trips.each {|t| puts t.inspect; puts "aaaaa";}
    end
  end

  class Trip
    attr_accessor :reisdeels, :stops

    def initialize
      @stops = []
      @reisdeels = []
    end
  end

  class ReisDeel
    attr_accessor :soort, :stops

    def initialize
      @stops = []
    end
  end

  class PricesResponse
    attr_accessor :tariffs

    def initialize
      @tariffs= {}
    end
  end

  class ProductPrice
    attr_accessor :type, :train_class, :amount
  end

  class UnplannedDisruption
    attr_accessor :id, :trip, :reason, :message, :datetime_string, :cause
  end

  class PlannedDisruption
    attr_accessor :id, :trip, :reason, :advice, :message, :cause
  end

  class Station
    attr_accessor :code, :type, :country, :short_name, :name, :long_name, :uiccode, :synonyms, :lat, :long
  end

  class InvalidStationNameError < StandardError
  end

  class MissingParameter < StandardError
  end

  class UnparseableXMLError < StandardError
  end

end
