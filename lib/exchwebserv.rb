#############################################################################
# Copyright © 2009 Dan Wanek <dan.wanek@gmail.com>
#
#
# This file is part of Viewpoint.
# 
# Viewpoint is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
# 
# Viewpoint is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
# Public License for more details.
# 
# You should have received a copy of the GNU General Public License along
# with Viewpoint.  If not, see <http://www.gnu.org/licenses/>.
#############################################################################
$:.unshift(File.dirname(__FILE__))
require 'rubygems'
#require 'highline/import'
require 'singleton'
require 'wsdl/exchangeServiceBinding'
require 'dm-core'
# --- Custom libs ---
require 'exchange_headers'
# --- Folder Types ---
require 'folder'
require 'calendar'
require 'mail'

require 'viewpoint'

# This class will act as the controller for a client connection to the
# Exchange web service.
class Viewpoint::ExchWebServ
	include Viewpoint
	include Singleton

	attr_reader :ews, :user, :authenticated

	def initialize
		@authenticated = false
		# Exchange webservice URL (probably ends in /exchange.asmx)
		@ews_endpoint  = ""
		@user = ""
		@pass = ""
		# Connection to Exchange web services.  You can get fetch this from an accessor later
		@ews  = nil

		# Do initial authentication
		do_auth
		
		# Set up database
		DataMapper.setup(:default, (ENV["DATABASE_URL"] || "sqlite3:///#{Dir.pwd}/viewpoint.db"))
		DataMapper.auto_upgrade!
	end

	def find_folders
		ff = FindFolderType.new()
		ff.xmlattr_Traversal = FolderQueryTraversalType::Deep
		ff.folderShape = FolderResponseShapeType.new( DefaultShapeNamesType::AllProperties )
		fid = NonEmptyArrayOfBaseFolderIdsType.new()
		fidt = DistinguishedFolderIdType.new
		fidt.xmlattr_Id = DistinguishedFolderIdNameType::Root
		fid.distinguishedFolderId = fidt
		ff.parentFolderIds = fid

		# FindFolderResponseType
		resp = @ews.findFolder(ff)

		# ArrayOfResponseMessagesType
		msgs = resp.responseMessages

		# Array of FindFolderResponseMessageType
		msgs.findFolderResponseMessage.each do |elem|
			# Mail Folders
			elem.rootFolder.folders.folder.each do |folder|
				if( (MailFolder.first(:folder_id => folder.folderId.xmlattr_Id)) == nil )
					MailFolder.new(folder) unless folder.folderClass == nil
				end
			end
			# CalendarFolderType
			elem.rootFolder.folders.calendarFolder.each do |folder|
				if( (CalendarFolder.first(:folder_id => folder.folderId.xmlattr_Id)) == nil )
					CalendarFolder.new(folder)
				end
			end
			#elem.rootFolder.folders.contactsFolder.each do |folder|
			#end
			#elem.rootFolder.folders.searchFolder.each do |folder|
			#end
			#elem.rootFolder.folders.tasksFolder.each do |folder|
			#end
		end
	end

	# Return folder
	# The default is to return a folder that is a subclass of Folder from the
	# SqliteDB, but if fetch_from_ews is set to true it will go out and return
	# the FolderType object from EWS.
	# Parameters:
	# 	folder_ids: NonEmptyArrayOfBaseFolderIdsType or String if fetch_from_ews is not set
	# 	fetch_from_ews: boolean
	# 	folder_shape: DefaultShapeNamesType
	def get_folder(folder_ids, fetch_from_ews = false, folder_shape = DefaultShapeNamesType::AllProperties)
		return Folder.first(:display_name => folder_ids) unless fetch_from_ews

		folder_shape = FolderResponseShapeType.new( folder_shape )
		get_folder = GetFolderType.new(folder_shape, folder_ids)
		
		resp = @ews.getFolder(get_folder).responseMessages.getFolderResponseMessage[0]
	end

	# Parameters:
	# 	display_name: String
	# 	fetch_from_ews: boolean
	# 	folder_shape: DefaultShapeNamesType
	def get_folder_by_name(display_name, fetch_from_ews = true, folder_shape = DefaultShapeNamesType::AllProperties)
		#folder_ids = NonEmptyArrayOfBaseFolderIdsType.new()
		dist_name = DistinguishedFolderIdType.new
		dist_name.xmlattr_Id = DistinguishedFolderIdNameType.new(display_name.downcase)
		#folder_ids.distinguishedFolderId = dist_name
		folder_ids = NonEmptyArrayOfBaseFolderIdsType.new(nil, [dist_name])

		get_folder(folder_ids, true, folder_shape)
	end

	# Parameters:
	# 	folder_id: String
	# 	change_key: String
	# 	folder_shape: DefaultShapeNamesType
	def get_folder_by_id(folder_id, change_key = nil, fetch_from_ews = true, folder_shape = DefaultShapeNamesType::AllProperties)
		folder_ids = NonEmptyArrayOfBaseFolderIdsType.new()
		folder_id_t = FolderIdType.new
		folder_id_t.xmlattr_Id = folder_id
		folder_id_t.xmlattr_ChangeKey = change_key unless change_key == nil
		folder_ids.folderId = folder_id
		folder_ids = NonEmptyArrayOfBaseFolderIdsType.new([folder_id_t], nil)

		get_folder(folder_ids, true, folder_shape)
	end


	private
	def do_auth
		retry_count = 0
		begin
			#@ews_endpoint  = ask("Exchange EWS Endpoint:  ") { |q| q.echo = true }
			#@user = ask("User:  ") { |q| q.echo = true }
			#@pass = ask("Pass:  ") { |q| q.echo = "*"}
			props = SOAP::Property.load(File.new("#{File.dirname(__FILE__)}/soap/property"))
			@user = props['exchange.ews.user']
			@pass = props['exchange.ews.pass']
			@ews_endpoint = props['exchange.ews.endpoint']

			@ews = ExchangeServiceBinding.new(@ews_endpoint)
			@ews.options["protocol.http.auth.ntlm"] = [@ews_endpoint.sub(/\/[^\/]+$/,'/'),@user,@pass]
			@ews.headerhandler << ExchangeHeaders.new

			# Log SOAP request and response for debugging.  Run ruby with the '-d' option.
			if($DEBUG) then
				@ews.wiredump_file_base = "viewpoint-soaplog"
			end

			# Do a ResolveNames operation to make sure that authentication works.
			# If you don't do an operation, you won't find out that bad credentials
			# were entered until later.  The ResolveNames operation is completely
			# arbitrary and could be any EWS call.
			# http://msdn.microsoft.com/en-us/library/bb409286.aspx
			rnt = ResolveNamesType.new(nil,@user)
			rnt.xmlattr_ReturnFullContactData = false
			ews.resolveNames(rnt)

		rescue SOAP::HTTPStreamError
			puts "Bad Login!  Try Again."
			if( retry_count < 2)
				retry_count += 1
				retry
			else
				puts "-----------------------------------------------------------"
				puts "Could not log into Exchange Web Services.  Make sure your information is correct"
				puts "End Point: #{@ews_endpoint}"
				puts "User: #{@user}"
				puts "-----------------------------------------------------------"
				return
			end
		end
		@authenticated = true
	end
end
