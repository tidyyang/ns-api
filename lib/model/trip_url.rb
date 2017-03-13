class TripUrl

  def initialize(url)
    raise InvalidURL, "You must give an url, ie http://www.ns.nl/api" unless url
    @url = url
  end

  def url (opts = {dateTime: nil, fromStation: "", toStation: ""})
    opts[:dateTime] = opts[:dateTime].strftime("%Y-%m-%dT%H:%M") if opts[:dateTime]
    uri = URI.escape(opts.collect{|k,v| "#{k}=#{v}"}.join('&'))
    "#{@url}?#{uri}"
  end

  class InvalidURL < StandardError
  end
end
