class RMT::Lockfile
  LOCKFILE_LOCATION = '/run/lock/rmt/.lock'.freeze
  ExecutionLockedError = Class.new(StandardError)

  class << self
    def lock
      # https://ruby-doc.org/core-2.5.0/File.html#method-i-flock
      File.open(RMT::Lockfile::LOCKFILE_LOCATION, File::RDWR | File::CREAT) do |f|
        if f.flock(File::LOCK_EX | File::LOCK_NB)
          f.flock(File::LOCK_UN) # unlock for writing the PID
          f.write(Process.pid.to_s)
          f.flock(File::LOCK_EX) # lock again
        else
          pid = File.read(RMT::Lockfile::LOCKFILE_LOCATION)
          raise ExecutionLockedError.new(
            "Process is locked by the application with pid #{pid}. Close this application or wait for it to finish before trying again\n"
          )
        end

        yield
      end
    end
  end
end