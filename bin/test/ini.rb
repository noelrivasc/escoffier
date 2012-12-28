#!/usr/bin/ruby -rubygems
# encoding: utf-8

require 'pp'
require 'inifile'

begin
  if ARGV.length != 1
    puts "* ERROR: Se recibieron " + String(ARGV.length) + " argumentos. Se esperaba 1."
    exit
  end
  
  ini_path  = ARGV[0]
  
  #Leer el archivo .ini
  settings  = IniFile.load ini_path
  pp settings['ingest']['template']
  
  puts "¡EXITO!"
  
rescue SystemExit
  puts "SystemExit: no se terminó la ejecución del script."
end

# file = IniFile.new()