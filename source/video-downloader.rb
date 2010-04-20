#!/usr/bin/ruby

require 'net/http'
require 'uri'
require 'cgi'

def report_progress(start, now, bytes, f_len)
	f_len_str = FileDownloader::bytes_siunit(f_len)
	dl_rate_str = '-.-- B/sec'
	eta_str = 'ETA: --:--:--'

	dl_rate = bytes / (now - start)
	
	if(dl_rate > 1.0) then
		dl_rate_str = "%s/sec"  % FileDownloader::bytes_siunit(dl_rate) if dl_rate > 1
		(eta_min, eta_sec) = ((f_len - bytes) / dl_rate).divmod(60)
		(eta_hr , eta_min) = eta_min.divmod(60)
		eta_str = "ETA: %02d:%02d:%02d" % [eta_hr.floor, eta_min.floor, eta_sec.floor] if eta_hr < 24.0

		if bytes == f_len then
			(eta_min, eta_sec) = (now - start).divmod(60)
			(eta_hr , eta_min) = eta_min.divmod(60)
			eta_str = "Total: %02d:%02d:%02d" % [eta_hr.floor, eta_min.floor, eta_sec.floor]
		end
	end

	# '\033[0K' is the ANSI escape sequence ESC[0K which deletes the line starting
	# from the cursor to the end of the line
	# http://ascii-table.com/ansi-escape-sequences.php
	print "\033[0KDone: %5.2f%% of %s at %s, %s\r" % [bytes/f_len * 100.0, f_len_str, dl_rate_str, eta_str]
	STDOUT.flush
end

class FDException < Exception
	def initialize(message = nil)
		super(message)
	end
end

class FileDownloader
	def self.bytes_siunit(length)
		suffix = ' KMGTPEZY'
		exp = (Math.log(length) / Math.log(1024.0)).floor
		conv_len = length / (1024.0 ** exp)
		fin_suffix = suffix[exp].chr == ' ' ? 'B' : "#{suffix[exp].chr}iB"
		"%6.2f %s" % [conv_len, fin_suffix]
	end

	def download_file(info_extractor, &p)
		video_info = info_extractor.info
		f_name = video_info[:video_title]
		download_file_r(video_info[:video_url], video_info[:video_title], &p)
	end

	private
	def download_file_r(url, f_name, &p)
		f_length = counter = 0
		start_t = Time.now

		f_mode = 'a+'
		f_name_dl = f_name + '.part'
		if !(counter = File.size?(f_name_dl)) then
			f_mode = 'w+'
			counter = 0
		end
		success = false

		p_dl = Proc.new { |response|
			if response.kind_of?(Net::HTTPOK) || response.kind_of?(Net::HTTPPartialContent) then
				f_length = response['content-length'].to_f
				f_length += counter if response.kind_of?(Net::HTTPPartialContent)
				
				raise FDException, "The file: \"#{f_name}\" already exists in the destination folder", caller if f_length == File.size?(f_name)

				File.open(f_name_dl, f_mode) do |file|
						response.read_body do |segment|
						file.write(segment)
						counter += segment.size
						yield start_t, Time.now, counter, f_length
					end
				end
				File.rename(f_name_dl, f_name)
				success = true
			elsif response.kind_of?(Net::HTTPRequestedRangeNotSatisfiable) then
				success = false
			else
				raise FDException, "Cannot download video, server responded with: \"#{response.class.name}\""
			end
		}

		if counter > 0 then
			puts "Resuming download at #{FileDownloader::bytes_siunit(counter)}"
			request_get(url, {'Range' => "bytes=#{counter}-"}) do |response|
				p_dl.call(response) do |start, now, bytes, length|
					yield start, now, bytes, length
				end
			end
		end

		if !success
			puts "Unable to resume download: #{response.message}, re-downloading file..." unless counter == 0
			request_get(url, nil) do |response|
				counter = 0
				f_mode = 'w+'
				p_dl.call(response) do |start, now, bytes, length|
					yield start, now, bytes, length
				end
			end
		end

		success
	end

	def request_get(url, header, limit = 5, &p)
		if limit > 0 then
			video_url = URI.parse(url)
			request_path =  video_url.request_uri
			redirected = false
			request = Net::HTTP::Get.new(request_path, header)
			response = nil
			Net::HTTP.start(video_url.host, video_url.port) do |http|
				response = http.request(request) do |resp|
					if resp.kind_of?(Net::HTTPFound) || resp.kind_of?(Net::HTTPSeeOther) then
						url = resp['location']	
						redirected = true
					else
						p.call(resp)
					end
				end
			end
			if redirected then
				puts "Redirecting to: #{url}"
				return request_get(url, header, limit - 1, &p)
			end
			response
		else
			raise FDException, 'Too many redirections!', call	
		end
	end
end

class IEException < Exception
	def initialize(message = nil)
		super(message)
	end
end

class InfoExtractor
	def initialize(url)
		@info = nil
		@url_origin = url
		@info_description = {
			:video_url		=> 'Real Video Url',
			:video_id		=> 'Video ID',
			:video_title	=> 'Video Title',
			:query_response => 'Response'
		}
	end

	private
	def extract
		# TODO: Fill this in later with generic extractor
	end

	public
	def info
		extract unless @info
		@info
	end

	def pretty_info
		result = Hash.new
		self.info.keys.each do |key|
			result[@info_description[key]] = self.info[key]
		end
		result
	end

	def video_url
		self.info[:video_url]
	end

	def video_title
		self.info[:video_title]
	end

	def info_description(symbol)
		self.info[symbol]
	end

	def self.valid_url?(url)
		return false
	end
end

class YouTubeIE < InfoExtractor
	@@valid_url  = /(?:http:\/\/)?(?:\w+\.)youtube\.com\/watch\?v=([a-zA-Z0-9_-]+)(?:\&(?:\S+$))?/
	# http://en.wikipedia.org/wiki/YouTube#Quality_and_codecs
	@@video_fmt  = {
		37 => '.mp4',
		22 => '.mp4',
		35 => '.flv',
		18 => '.mp4',
		34 => '.flv',
		17 => '.3gp',
		6  => '.flv',
		0  => '.flv',
		5  => '.flv',
		13 => '.3gp'
	}

	def initialize(url)
		super(url)
		@info_description[:video_fmt] = 'Video format'
	end
	
	private
	def extract
		@url_origin =~ @@valid_url	
		video_info_url = "http://www.youtube.com/get_video_info?&video_id=%s&el=detailpage" % $1
		url = URI.parse(video_info_url)
		res = Net::HTTP.start(url.host, url.port) { |http|
			http.get(video_info_url)
		}
		
		if res.kind_of?(Net::HTTPOK) then
			video_info = CGI::parse(CGI::unescape(res.body))
			if video_info.has_key?('errorcode') then
				reason = video_info['reason'].gsub('\+', ' ')
				raise IEException, "Fail to retrieve video info: %s with error code: %s" % reason, video_info['errorcode'], caller
			end
			best_fmt = parse_fmt_code(video_info['fmt_list'].first).first.to_i
			video_url =  "http://www.youtube.com/get_video?video_id=%s&t=%s&fmt=%s" % [$1, video_info['token'], best_fmt]

			url = URI.parse(video_url)
			res = Net::HTTP.start(url.host, url.port) { |http|
				http.get(url.request_uri)
			}
			raise IEException, "Youtube changed their protocol! Resolving video URL returns \
				: #{res.class.name}", caller if !res.kind_of?(Net::HTTPSeeOther) 
			@info = Hash.new unless @info
			@info[:video_url] =	res['location']
			@info[:video_id] = video_info['video_id'].to_s
			@info[:video_title] = video_info['title'].to_s + @@video_fmt[best_fmt]
			@info[:query_response] = res
			@info[:video_fmt] = best_fmt
		else
			raise IEException, "Fail retrieving video info", caller
		end
	end

	def parse_fmt_code(fmt_str)
		fmt_str.split(',').map do |arr|
			arr.split('/').first
		end
	end

	public
	def self.valid_url?(url)
		url =~ @@valid_url
	end
end

# Main function
if __FILE__ == $0 then
	if ARGV.size < 1
		puts 'usage flash_downloader.rb <url>'
	else
		extractors = Array.new
		ARGV.each do |arg|
			if YouTubeIE::valid_url?(arg) then
				extractors << YouTubeIE.new(arg)
			end
		end
		downloader = FileDownloader.new
		extractors.each do |ie|
			begin
				ie.pretty_info.sort.each do |key, value|
					puts "%-20s : %s" % [key, value]
				end
				downloader.download_file(ie) do | start, now, bytes, length |
					report_progress(start, now, bytes, length)
				end
			rescue Exception => ex
				puts ex.message
			end
			puts "\n\n"
		end
	end
end

