#!/usr/bin/ruby -rubygems
# encoding: utf-8

require_relative 'lib/build_fojas'

puts 'Iniciando Comanda: fojas con salsa de FOXML, término medio.'

begin
  if ARGV.length != 1
    raise ArgumentError.new "Se esperaba solo un argumento (la ruta al archivo INI de configuración para el proceso)."
    exit
  else
    ini_file = ARGV[0]
    raise IOError.new "Archivo inexistente: #{ini_file}" unless File.exists? ini_file
  end
rescue Exception => e
  puts "#{e.class}: #{e.message}"
end


f = BuildFojas.new ini_file
f.do_build