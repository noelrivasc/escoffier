# encoding: utf-8
require 'inifile'
require 'pp'
require 'mysql'
require 'fileutils'
require 'logger'

class BuildFojas
  def initialize(ini)
    check_env
    load_config ini
  end
  
  def check_env
    begin
      puts "Verificando existencia de $ESCOFFIER_HOME"
      env_exists = !ENV['ESCOFFIER_HOME'].nil? && File.directory?(ENV['ESCOFFIER_HOME'])
      raise "La variable de entorno $ESCOFFIER_HOME no existe o no apunta a un directorio" unless env_exists
      
    rescue Exception => e
      puts "#{e.class}: #{e.message}"
      exit
    end
  end
  
  def load_config(ini)
    begin
      @build_config_ini = File.expand_path ini
      puts "Cargando configuración de archivo #{@build_config_ini}"
      raise IOError.new "Archivo inexistente: #{@build_config_ini}" unless File.exists? @build_config_ini
      
      @global_config  = read_global_config
      @build_config   = read_build_config
      
    rescue Exception => e
      puts "#{e.class}: #{e.message}"
      exit
    end
  end
  
  def do_build
    # Preparar las fuentes de datos para la construcción
    prepare_data_table
    
    # Específicos para Foja
    list_files
    create_derivatives
    build_foxml
  end
  
  def prepare_data_table
    begin
      puts "Preparando tabla de datos"
      mysql_open

      m   = @mysql_con
      gc  = @global_config
      dbc = gc['db']
      bc  = @build_config
      gc  = bc['general']
      mtc = bc['metadata_table']
      pac = bc['file_paths']
      
      #DOES THE TABLE EXIST?
      r_exists      = m.query "SELECT table_name FROM information_schema.tables WHERE table_schema='#{dbc['db']}' AND table_name='#{mtc['temp_table']}'"
      table_exists  = r_exists.num_rows == 1
      
      #Si existe y no se supone que la reutilicemos, eliminarla
      if table_exists && gc['force_metadata_table'] == '1'
        puts "Eliminando tabla #{mtc['temp_table']}"
        m.query "DROP TABLE #{mtc['temp_table']}"
        table_dropped = true
      end
      
      #Si no existe o fue eliminada, crearla y poblarla nuevamente
      if !table_exists || table_dropped
        puts "Creando tabla #{mtc['temp_table']}"
        table_sql_file  = File.new expand_env mtc['table_schema']
        sql_create      = table_sql_file.read.gsub('[TABLENAME]', mtc['temp_table'])
        m.query sql_create
        
        #Poblar la tabla con los datos del CSV
        
        csv_path        = File.expand_path mtc['csv_meta']
        csv_filename    = csv_path.split('/').last
        tmp_dir         = '/tmp/escoffier'
        
        puts "Poblando tabla #{mtc['temp_table']} con el archivo #{csv_path}"
        
        if !File.directory? tmp_dir
          FileUtils.mkdir tmp_dir
        end
        
        FileUtils.copy csv_path, tmp_dir
        m.query "LOAD DATA INFILE '#{tmp_dir}/#{csv_filename}' INTO TABLE cdfm_efm_fotos CHARACTER SET 'utf8' FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"' IGNORE 1 LINES"
        FileUtils.rm "#{tmp_dir}/#{csv_filename}"
      end
      
    rescue   Mysql::Error => e
      puts e.errno
      puts e.error
      
    ensure
      mysql_close
    end
    
  end
  
  # Genera un arreglo en el cual cada elemento es también un arreglo que contiene:
  #    [:m_filename]  Nombre de archivo, en este caso imagen.tif
  #    [:m_fullpath]  Ruta completa al archivo, por ejemplo /users/alguien/arcghivos/imagenes/ingesta/imagen.tif
  #    [:m_relpath]   Ruta al archivo, relativa a la ruta de masters
  #    [:m_url]       URL del archivo, por ejemplo http://127.0.0.1/masters/imagen.tif
  
  # Además, en al generar los derivados se agregarán las urls a éstos, en
  #    [:jp2_url]     URL de jp2
  #    [:jpgm_url]    URL de jpgm
  #    [:jpgt_url]    URL de jpgt
  
  def list_files(extension='tif')
    begin
      puts "Creando lista de archivos master"
      fp = @build_config['file_paths']
      cp = @build_config['cupboard']
      path_masters  = File.expand_path "#{fp['kitchen']}#{fp['masters']}"
      ls_result     = `ls -R1 #{path_masters}`
      ls_lines      = ls_result.split("\n")
      ls_output     = []
      
      #puts ls_result

      #Este loop debe generar una lista de archivos, cada uno con su ruta 
      # relativa a [kitchen] y su ruta via http
      base = ''
      ls_lines.each do |ln|
        ln.strip!
        #Si la línea termina con ":", cambiar la ruta base
        if ln.end_with?(':')
          raise "Esto no parece una ruta absoluta, no empieza con /:  #{ln}" unless ln.start_with?('/')
          base = ln[path_masters.length..ln.length-2]
          base = '/' unless base != ''
          base = "#{base}/" unless base.end_with? '/'
          next
        
        # De lo contrario, incluir 
        elsif ln.end_with?('.tiff', '.tif')
          relative  = "#{base}#{ln}"
          full      = "#{path_masters}#{relative}"
          url       = "#{cp['host']}#{cp['masters']}#{relative}"
          item      = {
            :m_filename => ln,
            :m_fullpath => full,
            :m_relpath  => relative,
            :m_url      => url
          }
          ls_output.push item
        end
      end
      
      @masters_list = ls_output
      
    rescue Exception => e
      puts "#{e.class}: #{e.message}"
      exit
    end
    
  end
  
  def create_derivatives
    puts "Creando archivos derivados del master .tif"
    
    bc = @build_config
    gc = bc['general']
    fp = bc['file_paths']
    cp = bc['cupboard']
    pa = File.expand_path "#{fp['kitchen']}#{fp['prep_area']}"
    
    begin
      #Preparar contenedores
      if !File.directory? "#{pa}/jp2"
        FileUtils.mkdir_p "#{pa}/jp2"
      end

      if !File.directory? "#{pa}/jpgm"
        FileUtils.mkdir_p "#{pa}/jpgm"
      end

      if !File.directory? "#{pa}/jpgt"
        FileUtils.mkdir_p "#{pa}/jpgt"
      end
      
      url_prep = "#{cp['host']}#{cp['prep_area']}"
      
      @masters_list.each do |master|
        puts "Creando derivados de #{master[:m_filename]}"
        #Crear JP2
        jp2_filename  = "#{master[:m_filename]}.jp2"
        jp2_path      = "#{pa}/jp2/#{jp2_filename}"
        if !File.exists?(jp2_path) || gc['force_derivatives'] == '1' || gc['force_jp2'] == '1'
          puts "JP2"
          cmd_jp2   = "kdu_compress -i #{master[:m_fullpath]} -o #{jp2_path} " + ' -rate 0.5 Clayers=1 Clevels=7 "Cprecincts={256,256},{256,256},{256,256},{128,128},{128,128},{64,64},{64,64},{32,32},{16,16}" "Corder=RPCL" "ORGgen_plt=yes" "ORGtparts=R" "Cblk={32,32}" Cuse_sop=yes'
          r_jp2     = `#{cmd_jp2}`
          
          raise "Hay un error en la ejecución de kdu_compress" unless $?.exitstatus == 0
        end
        url_jp2   = "#{url_prep}/jp2/#{jp2_filename}"
        master[:jp2_url] = url_jp2

        #Crear JPG tamaño medio
        jpgm_filename = "#{master[:m_filename]}.med.jpg"
        jpgm_path     = "#{pa}/jpgm/#{jpgm_filename}"
        if !File.exists?(jpgm_path) || gc['force_derivatives'] == '1' || gc['force_jpgm'] == '1'
          puts "JPG 600x800"
          cmd_jpgm  = "convert -resize 600x800 \"#{master[:m_fullpath]}\"[0] \"#{jpgm_path}\""
          r_jpgm    = `#{cmd_jpgm}`
          
          raise "Hay un error en la creación del JPG mediano" unless $?.exitstatus == 0
        end
        url_jpgm  = "#{url_prep}/jpgm/#{jpgm_filename}"
        master[:jpgm_url] = url_jpgm

        #Crear thumb JPG
        jpgt_filename = "#{master[:m_filename]}.thumb.jpg"
        jpgt_path     = "#{pa}/jpgt/#{jpgt_filename}"
        if !File.exists?(jpgt_path) || gc['force_derivatives'] == '1' || gc['force_jpgt'] == '1'
          puts "Thumbnail JPG"
          cmd_jpgt  = "convert \"#{master[:m_fullpath]}\"[0] -thumbnail x2000 -thumbnail x450  -resize '450x<' -resize 50% -fuzz 1% -trim +repage -gravity center -crop 200x200+0+0 +repage -format jpg -quality 100 \"#{jpgt_path}\""
          r_jpgt    = `#{cmd_jpgt}`
          
          raise "Hay un error en la creación del thumbnail JPG" unless $?.exitstatus == 0
        end
        url_jpgt  = "#{url_prep}/jpgt/#{jpgt_filename}"
        master[:jpgt_url] = url_jpgt
      end
      
      pp @masters_list
    rescue Exception => e
      puts "#{e.class}: #{e.message}"
    end
  end
  
  def build_foxml
    bc = @build_config
    fp= bc['file_paths']
    
    puts "Generando datos para la construcción de los FOXML"
    logs_path = File.expand_path "#{fp['kitchen']}/logs"
    FileUtils.mkdir_p logs_path unless File.directory? logs_path
    foxml_log = Logger.new("#{logs_path}/foxml.log")
    begin
      @masters_list.each do |master|
        #pid
        pid       = master[:m_filename].split('.')[0..-2].join('.')
        pid_valid = /^[a-zA-Z_]+\.C{1}_{1}[0-9]+\.E{1}_{1}[0-9]+\.S{1}_{1}[0-9]+\.F{1}_{1}[0-9\-]+$/.match(pid)
        if !pid_valid
          foxml_log.debug "PID de foja inválido: #{pid}"
          next
        end
        
        # Número de serie
        r_serie = /^[a-zA-Z_]+\.C{1}_{1}[0-9]+\.E{1}_{1}[0-9]+\.S{1}_{1}(?<serie>[0-9]+)\.F{1}_{1}[0-9\-]+$/.match(pid)
        serie   = r_serie[:serie]
        if !serie
          foxml_log.debug "Imposible obtener número de serie en pid #{pid}."
          next
        end
        
        #números de página
        r_paginas = /^[a-zA-Z_]+\.C{1}_{1}[0-9]+\.E{1}_{1}[0-9]+\.S{1}_{1}[0-9]+\.F{1}_{1}(?<paginas>[0-9\-]+)$/.match(pid)
        paginas   = r_paginas[:paginas]
        if paginas
          a_paginas = paginas.split('-')
          if a_paginas.length == 1
            pag_inicio  = pag_final = a_paginas[0]
          elsif a_paginas.length == 2
            pag_inicio  = a_paginas[0]
            pag_final   = a_paginas[1]
          else
            foxml_log.debug "Imposible obtener números de página en #{pid} (1)"
          end
        else
          foxml_log.debug "Imposible obtener números de página en #{pid} (2)"
        end
        
        #construir rels-ext
        #construir FOXML
      end
    rescue Exception => e
      puts "#{e.class}: #{e.message}"
    end
    
  end
  
  
  private
  
  def mysql_open
    begin
      if @mysql_con.nil?
        gc  = @global_config
        dbc = gc['db']
        @mysql_con = Mysql.new dbc['host'], dbc['user'], dbc['pass'], dbc['db']
      end
      
    rescue Mysql::Error => e
      puts e.errno
      puts e.error
    end
  end
  
  def mysql_close
    @mysql_con.close if @mysql_con
  end
  
  def expand_env(str)
    return str.gsub(/\$\w+/) {|m| ENV[m[1..-1]]}
  end
  
  def read_global_config
    global_config_ini = expand_env "$ESCOFFIER_HOME/config/global.ini"
    
    if File.exists? global_config_ini
      settings = IniFile.load global_config_ini
    end
    
    return settings
  end
  
  def read_build_config
    settings = IniFile.load @build_config_ini
    return settings
  end
end