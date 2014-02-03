require 'rubygems'
require 'ruby-box'
require 'json'
require 'yaml'
require 'pp'

module RubyBox
  class File < Item
    def download_all_pages(page="1")
      uri = URI.parse( "#{RubyBox::API_URL}/#{resource_name}/#{id}/representation/preview.png?min_width=2048&page=#{page}")
      request = Net::HTTP::Get.new( uri.request_uri )
      resp = @session.request_with_response(uri, request)
      if resp.code.to_i == 202 && resp['retry-after']
        print "."
        sleep(resp['retry-after'].to_i)
        return download_all_pages(page)
      end
      directory_name = "#{Skyport::Collector::BASE_LOCAL_PATH}/#{self.sha1}"
      ::Dir.mkdir(directory_name) unless ::File.exists?(directory_name)
      ::File.open("#{directory_name}/page_#{page}.png", 'w') {|f| f.write(resp.body)}
      if !resp['Link']
        puts resp.to_hash.inspect
        puts resp.code.inspect
        puts resp.inspect
        puts resp.body.inspect
        return
      end
      matches = resp['Link'].scan(/page=(\d*)/).flatten
      next_page = matches[-2]
      if next_page.to_i > page.to_i
        download_all_pages(next_page)
      else
        return page
      end
    end
  end
end

module RubyBox
  class Folder < Item
    def all_files_recursively
      puts "Recursing into #{self.to_s}..."
      self.items.collect do |item|
        if item.is_a? Folder
          item.all_files_recursively
        else
          item
        end
      end.flatten
    end

    def all_folders_recursively
      self.folders.collect do |folder|
        [folder, folder.all_folders_recursively] if folder.is_a? Folder
      end.flatten
    end
  end
end

module RubyBox
  class Session
    def request_with_response(uri, request, raw=false, retries=0)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.ssl_version = :SSLv3
      #http.set_debug_output($stdout)

      if @access_token
        request.add_field('Authorization', "Bearer #{@access_token.token}")
      else
        request.add_field('Authorization', build_auth_header)
      end

      response = http.request(request)

      if response.is_a? Net::HTTPNotFound
        raise RubyBox::ObjectNotFound
      end

      # Got unauthorized (401) status, try to refresh the token
      if response.code.to_i == 401 and @refresh_token and retries == 0
        refresh_token(@refresh_token)
        request_with_response(uri, request, raw, retries + 1)
      end

      sleep(@backoff) # try not to excessively hammer API.

      response
    end

    def pure_access_token
      @access_token
    end

    def pure_refresh_token
      @refresh_token
    end
  end
end


module Skyport
  class Collector
    CREDENTIALS_FILE = 'credentials.yml'
    PAGE_COUNT_FILE = 'page_counts.yml'
    BASE_BOX_PATH = 'Path In Box/With Spaces'
    BASE_LOCAL_PATH = '/path/on/disk'

    @credentials = nil
    @session = nil
    @client = nil
    @page_counts = {}

    def load_credentials
      print "Loading credentials..."
      @credentials = YAML::load_file(File.join(__dir__, CREDENTIALS_FILE)) if File.exists?(File.join(__dir__, CREDENTIALS_FILE))
      puts "done."
    end

    def save_credentials
      print "Saving credentials..."
      @credentials[:access_token] = @session.pure_access_token.token
      @credentials[:refresh_token] = @session.pure_access_token.refresh_token
      File.open(File.join(__dir__, CREDENTIALS_FILE), 'w') {|f| f.write(YAML.dump(@credentials)) }
      puts "done."
    end

    def load_page_count_file
      print "Loading page count file..."
      @page_counts = YAML::load_file(File.join(__dir__, PAGE_COUNT_FILE)) if File.exists?(File.join(__dir__, PAGE_COUNT_FILE))
      puts "done."
    end

    def save_page_count_file
      print "Saving page count..."
      File.open(File.join(__dir__, PAGE_COUNT_FILE), 'w') {|f| f.write(YAML.dump(@page_counts)) }
      puts "done."
    end

    def authenticate
      print "Authenticating..."
      @session = RubyBox::Session.new(@credentials)
      @client = RubyBox::Client.new(@session)
      puts "done."
      return @client
    end

    def ensure_directory_structure
      print "Ensuring local directory exists..."
      FileUtils.mkdir_p(BASE_LOCAL_PATH) unless File.exists?(BASE_LOCAL_PATH)
      puts "done."
    end

    def all_files_on_box
      print "Retrieving list of files on Box..."
      files = @client.folder(BASE_BOX_PATH).all_files_recursively
      puts "done."
      return files
    end

    def all_folders_on_box
      print "Retrieving list of folders on Box..."
      folders = @client.folder(BASE_BOX_PATH).all_folders_recursively
      puts "done."
      return folders
    end

    def all_local_files
      return Dir.glob("#{BASE_LOCAL_PATH}/*").collect{|dir|dir.split('/').last}
    end


    def delete_local_files(locals, sha1s)
      # Delete files not on Box
      puts "Checking for files in #{BASE_LOCAL_PATH} that don't exist in #{BASE_BOX_PATH}:"
      locals.each do |file|
        if !file.include?('.json') && !sha1s.include?(file)
          print "Deleting #{BASE_LOCAL_PATH}/#{file}..."
          FileUtils.remove_dir("#{BASE_LOCAL_PATH}/#{file}")
          puts "done."
        end
      end
    end

    def download_new_files(files, locals)
      # Download new files
      puts "Checking for files in #{BASE_BOX_PATH} that don't exist in #{BASE_LOCAL_PATH}:"
      files.each do |file|
        if !locals.include?(file.sha1)
          print "Downloading files to #{BASE_LOCAL_PATH}/#{file.sha1}..."
          @page_counts ||= {}
          @page_counts[file.sha1] = file.download_all_pages
          puts "done."
        end
      end
    end

    def write_configs(folders)
      config = {}
      folders.each do |folder|
        metadata = get_metadata_hash(folder.description)
        if metadata["key"]
          config[metadata["key"]] ||= metadata
          config[metadata["key"]]["data"] ||= {}
          folder.all_files_recursively.each do |file|
            config[metadata["key"]]["data"][file.sha1] = {"pages" => @page_counts[file.sha1]}
          end
        end
      end
      config.each do |key, config|
        File.open(File.join(BASE_LOCAL_PATH, "#{key}.json"), 'w') {|f| f.write(config.to_json) }
      end
    end

    def get_metadata_hash(string)
      output = {}
      pairs = string.split(',')
      pairs.compact.each do |pair|
        key, value = pair.split(':')
  if key and value
          output[key.strip] = value.strip
  end
      end
      return output
    end

    def run!
      load_credentials
      load_page_count_file

      ensure_directory_structure

      authenticate

      files = all_files_on_box
      locals = all_local_files
      sha1s = files.collect{|file|file.sha1}

      # delete_local_files(locals, sha1s)
      download_new_files(files, locals)

      folders = all_folders_on_box
      write_configs(folders)

      @session.refresh_token(@session.pure_refresh_token)
      save_credentials
      save_page_count_file
    end
  end
end

if __FILE__==$0
  # this will only run if the script was the main, not load'd or require'd
  skyport = Skyport::Collector.new
  skyport.run!
end
