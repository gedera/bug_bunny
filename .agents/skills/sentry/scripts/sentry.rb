#!/usr/bin/env ruby
# frozen_string_literal: true

# Helper para interactuar con la API de Sentry self-hosted de Wispro.
# Uso: ruby sentry.rb <comando> [opciones]
#
# Comandos:
#   projects                          — Lista todos los proyectos
#   issues <project_slug> [opciones]  — Lista issues de un proyecto
#   issue <issue_id>                  — Detalle de un issue
#   events <issue_id> [--full]        — Eventos de un issue
#   search <project_slug> <query>     — Busca issues por texto
#   resolve <issue_id>                — Resuelve un issue
#   ignore <issue_id>                 — Ignora un issue
#   assign <issue_id> <username>      — Asigna un issue

require 'net/http'
require 'uri'
require 'json'
require 'openssl'

module Sentry
  URL = ENV['SENTRY_URL'] || 'https://sentry.cloud.wispro.co'
  TOKEN = ENV['SENTRY_TOKEN']
  ORG = ENV['SENTRY_ORG'] || 'wispro'

  class << self
    def run(args)
      unless TOKEN
        puts "ERROR: SENTRY_TOKEN no configurado en el entorno."
        exit 1
      end

      command = args.shift
      case command
      when 'projects'    then projects
      when 'issues'      then issues(args)
      when 'issue'       then issue(args.first)
      when 'events'      then events(args)
      when 'search'      then search(args)
      when 'resolve'     then update_status(args.first, 'resolved')
      when 'ignore'      then update_status(args.first, 'ignored')
      when 'assign'      then assign(args[0], args[1])
      else
        puts USAGE
      end
    end

    private

    USAGE = <<~TEXT
      Uso: ruby sentry.rb <comando> [opciones]

      Comandos:
        projects                              Lista todos los proyectos
        issues <project_slug> [--period=24h]  Lista issues (default: 24h, unresolved)
        issue <issue_id>                      Detalle de un issue
        events <issue_id> [--full]            Eventos de un issue
        search <project_slug> <query>         Busca issues por texto
        resolve <issue_id>                    Resuelve un issue
        ignore <issue_id>                     Ignora un issue
        assign <issue_id> <username>          Asigna un issue
    TEXT

    def projects
      data = get("/organizations/#{ORG}/projects/")
      data.each do |p|
        puts "  #{p['slug'].ljust(30)} #{p['name']}"
      end
    end

    def issues(args)
      slug = args.shift
      period = extract_flag(args, '--period') || '24h'

      data = get("/projects/#{ORG}/#{slug}/issues/?statsPeriod=#{period}&query=is:unresolved")
      print_issues(data)
    end

    def issue(issue_id)
      data = get("/organizations/#{ORG}/issues/#{issue_id}/")
      puts "  ##{data['shortId']} — #{data['title']}"
      puts "  Level: #{data['level']} | Count: #{data['count']} | Users: #{data['userCount']}"
      puts "  First: #{data['firstSeen']} | Last: #{data['lastSeen']}"
      puts "  Status: #{data['status']}"
      puts "  Assigned: #{data.dig('assignedTo', 'name') || 'nadie'}"
      puts "  Link: #{data['permalink']}"
    end

    def events(args)
      issue_id = args.shift
      full = args.include?('--full')
      params = full ? '?full=true&limit=3' : '?limit=5'

      data = get("/organizations/#{ORG}/issues/#{issue_id}/events/#{params}")
      data.each do |event|
        puts "\n  Event #{event['eventID'][0..7]} — #{event['dateCreated']}"
        puts "  #{event['title']}"

        next unless full && event['entries']

        event['entries'].each do |entry|
          next unless entry['type'] == 'exception'

          entry.dig('data', 'values')&.each do |exc|
            puts "  Exception: #{exc['type']}: #{exc['value']}"
            frames = exc.dig('stacktrace', 'frames') || []
            frames.select { |f| f['inApp'] }.last(5).each do |frame|
              puts "    #{frame['filename']}:#{frame['lineNo']} in #{frame['function']}"
            end
          end
        end
      end
    end

    def search(args)
      slug = args.shift
      query = args.join(' ')
      data = get("/projects/#{ORG}/#{slug}/issues/?query=#{URI.encode_www_form_component(query)}&statsPeriod=24h")
      print_issues(data)
    end

    def update_status(issue_id, status)
      data = put("/organizations/#{ORG}/issues/#{issue_id}/", { status: status })
      puts "  Issue ##{issue_id} → #{data['status']}"
    end

    def assign(issue_id, username)
      data = put("/organizations/#{ORG}/issues/#{issue_id}/", { assignedTo: username })
      puts "  Issue ##{issue_id} → asignado a #{data.dig('assignedTo', 'name') || username}"
    end

    def print_issues(data)
      if data.empty?
        puts "  Sin issues encontrados."
        return
      end

      data.each do |i|
        level = i['level'].upcase.ljust(7)
        count = "x#{i['count']}".ljust(6)
        puts "  #{level} #{count} ##{i['shortId'].ljust(15)} #{i['title'][0..80]}"
      end
    end

    # --- HTTP ---

    def get(path)
      request(:get, path)
    end

    def put(path, body)
      request(:put, path, body)
    end

    def request(method, path, body = nil)
      uri = URI.parse("#{URL}/api/0#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      req = case method
            when :get then Net::HTTP::Get.new(uri)
            when :put then Net::HTTP::Put.new(uri)
            end

      req['Authorization'] = "Bearer #{TOKEN}"
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body) if body

      response = http.request(req)

      unless response.code.start_with?('2')
        puts "  ERROR: HTTP #{response.code} — #{response.body[0..200]}"
        exit 1
      end

      JSON.parse(response.body)
    rescue StandardError => e
      puts "  ERROR: #{e.message}"
      exit 1
    end

    def extract_flag(args, flag)
      idx = args.index { |a| a.start_with?(flag) }
      return nil unless idx

      value = args.delete_at(idx)
      value.include?('=') ? value.split('=', 2).last : args.delete_at(idx)
    end
  end
end

Sentry.run(ARGV.dup) if __FILE__ == $PROGRAM_NAME
