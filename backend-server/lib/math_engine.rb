require 'ffi'

module BiometricMath
  extend FFI::Library
  
  # 1. Load the library we just compiled in the native-engine folder
  # On Windows, this might look for .dll; on Linux/Android, it's .so
  ffi_lib File.expand_path('../../../native-engine/build/biometric_math.so', __FILE__)

  # 2. Define the C function signature so Ruby knows what to send
  # calculate_distance(float* attempt, float* profile, int length)
  attach_function :calculate_distance, [:pointer, :pointer, :int], :float
end

class MathEngine
  def self.get_score(attempt_array, profile_array)
    # Convert Ruby arrays into C-style "float" pointers
    attempt_ptr = FFI::MemoryPointer.new(:float, attempt_array.size)
    attempt_ptr.put_array_of_float(0, attempt_array)

    profile_ptr = FFI::MemoryPointer.new(:float, profile_array.size)
    profile_ptr.put_array_of_float(0, profile_array)

    # Call the C function and return the result
    BiometricMath.calculate_distance(attempt_ptr, profile_ptr, attempt_array.size)
  end
end