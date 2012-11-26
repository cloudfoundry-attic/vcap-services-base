require 'base/datamapper_l'

LOCK_FILE = "/tmp/base_dmtest.lock"
LOCALDB_FILE = "/tmp/base_dmtest.db"

class DataMapperTests

  def self.clean_lock_file
    File::delete(LOCK_FILE) if File::exists?(LOCK_FILE)
    File::delete(LOCALDB_FILE) if File::exists?(LOCALDB_FILE)
    DataMapper.instance_variable_set(:@lock, nil)
  end
end
