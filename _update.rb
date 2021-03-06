#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'

require 'pathname'
require 'yaml'
require 'uri'
require 'json'

require 'sequel'
require 'sqlite3'
require 'taglib2'

config = YAML.load_file(ARGV[0] ? ARGV[0] : 'config.yaml')

# db connect
DB = Sequel.connect(config["database"])

# db init
DB.transaction do
  unless DB.table_exists?(:filetree)
    DB.create_table :filetree do
      primary_key :id, :type => Bignum
      foreign_key :parent_id, :filetree, :index => true, :null => true, :on_delete => :cascade
      String :name, :null => false
      String :fullpath, :null => false
      Bignum :mtime, :null => false
      Boolean :directory, :null => false
    end
  end

  if DB[:filetree][:id => 0].nil?
    DB[:filetree].insert(:id => 0, :parent_id => nil, :name => '', :fullpath => '', :mtime => 0, :directory => true)
  end

  DB.create_table? :media do
    foreign_key :file_id, :filetree, :primary_key => true, :null => false, :on_delete => :cascade

    String :title, :null => true
    String :artist, :null => true
    String :album, :null => true
    String :genre, :null => true
    Integer :track, :null => true

    Integer :length, :null => true # in seconds
  end
end

EXCLUDE_FILES = /(?:^Makefile$)|(?:\.(?:db|jpg|jpeg|png|txt|lrc|doc|ini|pdf|abc|mid|flv|webm|aac|mp4)$)/i

PATHSEP_REGEX = Regexp.union(*[File::SEPARATOR, File::ALT_SEPARATOR].compact)
class FS_File
  attr_reader :path, :name, :mtime

  def initialize(path, stat, name)
    @path = path
    @mtime = stat.mtime.to_i
    @name = name
  end
end

class FS_Directory
  attr_reader :path, :name

  def initialize(path, name)
    @path = path
    @name = name
  end

  def directories
    read unless @directories
    @directories
  end

  def files
    read unless @files
    @files
  end

protected
  def read
    @directories = []
    @files = []
    entries = Dir.foreach(@path) do |name|
      next if '.' == name[0]
      path = File.join(@path, name)
      begin
        s = File.lstat(path)
        if s.directory?
          @directories << FS_Directory.new(path, name)
        elsif s.file? and !EXCLUDE_FILES.match(name)
          @files << FS_File.new(path, s, name)
        end
      rescue Exception => e
        puts "Skipping #{path}: #{e}"
      end
    end
  end
end

class FS_Source
  attr_reader :path, :name

  def initialize(path, sources, name = nil)
    @path = path
    @sources = sources
    @name = name
  end

  def directories
    read unless @directories
    @directories
  end

  def files
    []
  end

protected
  def read
    @directories = []
    splits = {}
    names = @sources.map do |path|
      fst, rem = path.split(PATHSEP_REGEX, 2)
      (splits[fst] ||= []) << rem
    end
    splits.each do |fst, rems|
      path = File.join(@path, fst)
      next unless File.directory? path
      if rems.include? nil
        @directories << FS_Directory.new(path, fst)
      else
        @directories << FS_Source.new(path, rems, fst)
      end
    end
  end
end


class FileTree < Sequel::Model(:filetree)
  one_to_many :children, :class => :FileTree, :key => :parent_id
  many_to_one :parent, :class => :FileTree
  one_to_one :media, :class => :Media, :key => :file_id

  subset :directories, :directory => true
  subset :files, :directory => false

  def directories
    children_dataset.directories
  end

  def files
    children_dataset.files
  end

  def self.cleanup
    dead = DB["SELECT DISTINCT a.id AS id FROM filetree a LEFT JOIN filetree b ON a.parent_id = b.id WHERE b.id IS NULL AND a.parent_id IS NOT NULL"]
    while dead.count > 0
      FileTree[:id => dead.map(:id)].delete
    end
  end
end

class Media < Sequel::Model(:media)
  set_primary_key :file_id
  many_to_one :file, :class => :FileTree

  def self.cleanup
    dead = DB["SELECT DISTINCT a.file_id AS id FROM media a LEFT JOIN filetree b ON a.file_id = b.id WHERE b.id IS NULL"]
    while dead.count > 0
      Media[:id => dead.map(:id)].delete
    end
  end
end

class UpdateEntry
  attr_reader :dbobject, :fsobject

  def initialize(dbo, fso)
    @dbobject = dbo
    @fsobject = fso
  end

  def execute
    @media = @dbobject.media
    begin
      tag = TagLib::File.new(@fsobject.path)

      if @media.nil?
        @media = Media.new(:file => @dbobject)
      end

      title = tag.title
      title = "<#{@fsobject.name}>" if title.nil? or '' == title

      @media.set(
        :title => title,
        :artist => tag.artist,
        :album => tag.album,
        :track => tag.track,
        :genre => tag.genre,
        :length => tag.length
      )

      @media.save
      @dbobject.update(:mtime => @fsobject.mtime)
    rescue Exception => e
      @media.delete unless @media.nil? or !@media.exists?
      @dbobject.update(:mtime => 0)
      puts "Cannot read #{@fsobject.path}: #{e}"
      return
    end
  end
end

class PathMapping
  def initialize(config)
    @map = {}
    config["sources"].each do |source|
      local = Pathname.new(source["local"]).realpath.to_s
      @map[local] = source["url"]
    end
  end

  def map(path)
    @map.each do |local,url|
      if path[0, local.length] == local
        append = path[local.length..-1]
        append = append.gsub(PATHSEP_REGEX, '/') # fix path separators
        append = URI::escape(URI::escape(append), '?') # first regular escape, then escape ? too
        return url + append
      end
    end
  end

  def locals
    @map.keys
  end
end



def walk(update_list, fs, db)
  fsfiles = Hash[fs.files.map { |f| [f.name, f] }]
  fsdirs = Hash[fs.directories.map { |d| [d.name, d] }]

  # First: purge all old db entries
  db.files.each do |f|
    unless fsfiles.has_key? f.name
      # puts "Purge file from db: #{f.name} #{fsfiles[f.name].inspect}"
      f.delete
    end
  end

  db.directories.each do |d|
    unless fsdirs.has_key? d.name
      # puts "Purge dir from db: #{d.name} #{fsdirs[d.name].inspect}"
      d.delete
    end
  end

  # check files
  dbfiles = Hash[db.files.map { |f| [f.name, f] }]
  fsfiles.each do |name, fsf|
    dbf = dbfiles[name]
    if dbf.nil?
      # puts "New file: #{fsf.path}"
      dbf = FileTree.create(:parent => db, :name => name, :fullpath => fsf.path, :mtime => 0, :directory => false)
      dbf.save
      update_list << UpdateEntry.new(dbf, fsf)
    elsif dbf.mtime < fsf.mtime
      update_list << UpdateEntry.new(dbf, fsf)
    end
  end

  # check dirs
  dbdirs = Hash[db.directories.map { |d| [d.name, d] }]
  fsdirs.each do |name, fsd|
    dbd = dbdirs[name]
    if dbd.nil?
      # puts "New directory: #{fsd.path}"
      dbd = FileTree.create(:parent => db, :name => name, :fullpath => fsd.path, :mtime => 0, :directory => true)
      dbd.save
    end
    walk(update_list, fsd, dbd)
  end
end

class WebDB
  def initialize(mapping)
    @mapping = mapping
    @db = {
      :files => [],
      :albums => [],
      :artists => []
    }
    @files = @db[:files]
    @albums = @db[:albums]
    @artists = @db[:artists]
    @halbums = {}
    @hartists = {}
  end

  def add(media)
    albumid = add_album(media.album)
    artistid = add_artist(media.artist)
    fileid = @files.length
    @files << {
      :name => media.title,
      :url => @mapping.map(media.file.fullpath),
      :artist_id => artistid,
      :album_id => albumid,
      :track => media.track,
      :genre => media.genre,
      :length => media.length
    }

    (@albums[albumid][:artists] << artistid).uniq!
    @albums[albumid][:titles] << fileid
    (@artists[artistid][:albums] << albumid).uniq!
    @artists[artistid][:titles] << fileid
  end

  def result
    @db
  end

protected
  def add_album(album)
    if @halbums.has_key?(album)
      return @halbums[album]
    end
    id = @albums.length
    @albums << { :name => album, :artists => [], :titles => [] }
    @halbums[album] = id
    return id
  end

  def add_artist(artist)
    if @hartists.has_key?(artist)
      return @hartists[artist]
    end
    id = @artists.length
    @artists << { :name => artist, :albums => [], :titles => [] }
    @hartists[artist] = id
    return id
  end
end


update_list = []

mapping = PathMapping.new(config)
webdb = WebDB.new(mapping)

DB.transaction do
  fs_root = FS_Source.new('', mapping.locals).directories[0]
  walk(update_list, fs_root, FileTree[0])

  i = 0
  STDOUT.write "Updating: #{i}/#{update_list.length}\r"
  STDOUT.flush
  update_list.each do |e|
    i += 1
    STDOUT.write "Updating: #{i}/#{update_list.length}\r"
    STDOUT.flush
    e.execute
  end
  STDOUT.write(" " * "Updating: #{i}/#{update_list.length}".length + "\r")
  puts "Updating: done"

  # foreign key cascade delete might be not working
  FileTree.cleanup
  Media.cleanup

  Media.each do |media|
    webdb.add(media)
  end

  File.open(config['output-json'], "w+") { |f| f.write(webdb.result.to_json) }
end
