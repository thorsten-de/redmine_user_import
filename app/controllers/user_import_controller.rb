require 'tempfile'
require 'csv'

class UserImportController < ApplicationController
  before_action :require_admin
  helper :custom_fields


  USER_ATTRS = [:login, :password, :lastname, :firstname, :mail]

  PARSER = {
    "csv" => ->(field) {
      ->(row){ row[field] }
    },
    "val" => ->(value) {
      ->(row){ value }
    },
    "gen_passwd" => ->(_) {
      ->(row){ "passwd" }
    },
    "gen_login" => ->(row) {
      
    }
  }

  def get_parser(text)
    type, val = text.split('|')
    PARSER[type].(val)
  end

  def get_parsers(parser_defs)
    parser_defs
    .reject(&:blank?)
    .map { |p| get_parser(p) }
  end

  def build_parsers(field_defs)
    field_defs.transform_values do |parser_defs|
      get_parsers(parser_defs)
    end
  end

  def parse(parser, row)
    result = parser.(row)
    result.blank? ? nil : result
  end

  def parse_row(fields, row)
    fields.transform_values do |parsers|
      value = parsers.reduce(nil) do |value, parser|
        value || parse(parser, row)
      end
      value
    end
  end

  def index
  end

  def match
    # params
    file = params[:file]
    splitter = params[:splitter]
    wrapper = params[:wrapper]
    encoding = params[:encoding]

    @samples = []
    @headers = []
    @attrs = []

    # save import file
    @original_filename = file.original_filename
    tmpfile = Tempfile.new("redmine_user_importer", :encoding =>'ascii-8bit')
    if tmpfile
      tmpfile.write(file.read)
      tmpfile.close
      tmpfilename = File.basename(tmpfile.path)
      if !$tmpfiles
        $tmpfiles = Hash.new
      end
      $tmpfiles[tmpfilename] = tmpfile
    else
      flash.now[:error] = "Cannot save import file."
      return
    end

    session[:importer_tmpfile] = tmpfilename
    session[:importer_splitter] = splitter
    session[:importer_wrapper] = wrapper
    session[:importer_encoding] = encoding

    # display content
    begin
      CSV.open(tmpfile.path, {:headers=>true, :encoding=>encoding, :quote_char=>wrapper, :col_sep=>splitter}) do |csv|
        @samples = csv.read
        @headers = csv.headers  
      end
    rescue => ex
      flash.now[:error] = ex.message
    end


    # fields
    @attrs = USER_ATTRS.map do |attr|
      [t("field_#{attr}"), attr]
    end

    @custom_required = User
      .new
      .custom_field_values
      .select(&:required?)
      .map(&:custom_field)

    @header_options = @headers.map { |h| ["#csv|{h}", h]}
  
  end

  def result
    tmpfilename = session[:importer_tmpfile]
    splitter = session[:importer_splitter]
    wrapper = session[:importer_wrapper]
    encoding = session[:importer_encoding]

    if tmpfilename
      tmpfile = $tmpfiles[tmpfilename]
      if tmpfile == nil
        flash.now[:error] = l(:message_missing_imported_file)
        return
      end
    end

    # CSV fields map
    fields_map = params[:fields_map]
    # DB attr map

    parsers = fields_map.transform_values do |fields|
      build_parsers(fields)
    end

    @handle_count = 0
    @failed_rows = []

    CSV.foreach(tmpfile.path, {:headers=>true, :encoding=>encoding, :quote_char=>wrapper, :col_sep=>splitter}) do |row|
      user_values =  parse_row(parsers["user"], row).reject { |_, data| data.nil? }

      user_values["custom_field_values"] =  parse_row(parsers["custom_fields"], row).reject { |_, data| data.nil? }

      
      user = User.find_by_mail(user_values["mail"])
      unless user
        
        user = User.new({
          language: Setting.default_language,
        }.merge(user_values))        
        user.login = generate_login(user)

        p user
        

        if (!user.save()) then
          logger.info(user.errors.full_messages)
          @failed_rows << row
        end

        @handle_count += 1
      end

    end

    
    
    render json: {count: @handle_count, failed: @failed_rows}
  end

  def generate_login(user) 
    login = user.firstname[0] + user.lastname

    count = User.where("login like ?", "#{login}%").count
    count > 0 ? "#{login}#{count}" : login
  end

  def re2


    @handle_count = 0
    @failed_count = 0
    @failed_rows = Hash.new

    CSV.foreach(tmpfile.path, {:headers=>true, :encoding=>encoding, :quote_char=>wrapper, :col_sep=>splitter}) do |row|
      user = User.find_by_login(row[attrs_map["login"]])
      unless user
        user = User.new(:status => 1, :mail_notification => 0, :language => Setting.default_language)
        user.login = row[attrs_map["login"]]
        user.password = row[attrs_map["password"]]
        user.password_confirmation = row[attrs_map["password"]]
        user.lastname = row[attrs_map["lastname"]]
        user.firstname = row[attrs_map["firstname"]]
        user.mail = row[attrs_map["mail"]]
        user.admin = row[attrs_map["admin"]]
      else
        flash.now[:warning] = l(:message_unique_filed_duplicated)
        @failed_count += 1
        @failed_rows[@handle_count + 1] = row
      end

      if (!user.save(:validate => false)) then
        logger.info(user.errors.full_messages)
        @failed_count += 1
        @failed_rows[@handle_count + 1] = row
      end

      @handle_count += 1
    end # do

    if @failed_rows.size > 0
      @failed_rows = @failed_rows.sort
      @headers = @failed_rows[0][1].headers
    end
  end

  

end
