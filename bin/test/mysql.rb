#!/usr/bin/ruby

require 'mysql'


begin
    con = Mysql.new 'localhost', 'root', '000000'
    puts con.get_server_info
    rs = con.query 'SELECT VERSION()'
    puts rs.fetch_row
    
    #Crear una tabla temporal, cargar en ella un CSV de CDFM y después eliminarla
    # config  = IniFile.load
    
rescue Mysql::Error => e
    puts e.errno
    puts e.error
ensure
    con.close if con
end