module Dbox
  class DatabaseError < RuntimeError; end

  class Database
    include Loggable

    DB_FILENAME = ".dbox.sqlite3"

    def self.create(remote_path, local_path)
      db = new(local_path)
      if db.bootstrapped?
        raise DatabaseError, "Database already initialized -- please use 'dbox pull' or 'dbox push'."
      end
      db.boostrap(remote_path, local_path)
      db
    end

    def self.load(local_path)
      db = new(local_path)
      unless db.bootstrapped?
        raise DatabaseError, "Database not initialized -- please run 'dbox create' or 'dbox clone'."
      end
      db
    end

    # IMPORTANT: Database.new is private. Please use Database.create
    # or Database.load as the entry point.
    private_class_method :new
    def initialize(local_path)
      FileUtils.mkdir_p(local_path)
      @db = SQLite3::Database.new(File.join(local_path, DB_FILENAME))
      ensure_schema_exists
    end

    def ensure_schema_exists
      @db.execute_batch(%{
        CREATE TABLE IF NOT EXISTS metadata (
          id             integer PRIMARY KEY AUTOINCREMENT NOT NULL,
          local_path     varchar(255) NOT NULL,
          remote_path    varchar(255) NOT NULL,
          version        integer NOT NULL
        );
        CREATE TABLE IF NOT EXISTS entries (
          id             integer PRIMARY KEY AUTOINCREMENT NOT NULL,
          path           varchar(255) UNIQUE NOT NULL,
          is_directory   boolean NOT NULL,
          parent_id      integer,
          contents_hash  varchar(255),
          modified_at    datetime,
          revision       integer
        );
        -- TODO run performance tests with and without the indexes on DBs with 10,000s of records
        CREATE INDEX IF NOT EXISTS entry_paths ON entries(path);
        CREATE INDEX IF NOT EXISTS entry_parent_ids ON entries(parent_id);
      })
    end

    METADATA_COLS = [ :local_path, :remote_path, :version ] # don't need to return id
    ENTRY_COLS    = [ :id, :path, :is_directory, :parent_id, :contents_hash, :modified_at, :revision ]

    def boostrap(remote_path, local_path)
      @db.execute(%{
        INSERT INTO metadata (local_path, remote_path, version) VALUES (?, ?, ?);
      }, local_path, remote_path, 1)
      @db.execute(%{
        INSERT INTO entries (path, is_directory) VALUES (?, ?)
      }, "", 1)
    end

    def bootstrapped?
      n = @db.get_first_value(%{
        SELECT count(id) FROM metadata LIMIT 1;
      })
      n && n > 0
    end

    def metadata
      cols = METADATA_COLS
      res = @db.get_first_row(%{
        SELECT #{cols.join(',')} FROM metadata LIMIT 1;
      })
      make_hash(cols, res) if res
    end

    def root_dir
      find_entry("WHERE parent_id is NULL")
    end

    def find_by_path(path)
      find_entry("WHERE path=?", path)
    end

    def contents(dir_id)
      find_entries("WHERE parent_id=?", dir_id)
    end

    def subdirs(dir_id)
      find_entries("WHERE parent_id=? AND is_directory=1", dir_id)
    end

    def add_directory(path, parent_id, contents_hash, modified_at, revision)
      add_entry(:is_directory => true, :path => path, :parent_id => parent_id, :modified_at => modified_at, :revision => revision, :contents_hash => contents_hash)
    end

    def add_file(path, parent_id, modified_at, revision)
      add_entry(:is_directory => false, :path => path, :parent_id => parent_id, :modified_at => modified_at, :revision => revision)
    end

    private

    def find_entry(conditions = "", *args)
      # TODO run performance test on prepared statement
      res = @db.get_first_row(%{
        SELECT #{ENTRY_COLS.join(",")} FROM entries #{conditions} LIMIT 1;
      }, *args)
      entry_res_to_hash(res)
    end

    def find_entries(conditions = "", *args)
      # TODO run performance test on prepared statement
      res = @db.execute(%{
        SELECT #{ENTRY_COLS.join(",")} FROM entries #{conditions} ORDER BY path ASC;
      }, *args)
      if res
        res.map {|r| entry_res_to_hash(r) }
      else
        nil
      end
    end

    def add_entry(hash)
      h = hash.clone
      h[:modified_at]  = h[:modified_at].to_i if h[:modified_at]
      h[:is_directory] = (h[:is_directory] ? 1 : 0) unless h[:is_directory].nil?
      # TODO run performance test on prepared statement
      @db.execute(%{
        INSERT INTO entries (#{h.keys.join(",")})
        VALUES (#{(["?"] * h.size).join(",")});
      }, *h.values)
    end

    def entry_res_to_hash(res)
      if res
        h = make_hash(ENTRY_COLS, res)
        h[:is_directory] = (h[:is_directory] == 1)
        h[:modified_at]  = Time.at(h[:modified_at]) if h[:modified_at]
        h.delete(:contents_hash) unless h[:is_directory]
        h
      else
        nil
      end
    end

    def make_hash(keys, vals)
      if keys && vals
        raise ArgumentError.new("Can't make a hash with #{keys.size} keys and #{vals.size} vals") unless keys.size == vals.size
        out = {}
        keys.each_with_index {|k, i| out[k] = vals[i] }
        out
      else
        nil
      end
    end
  end
end