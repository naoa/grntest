# -*- coding: utf-8 -*-
#
# Copyright (C) 2012-2013  Kouhei Sutou <kou@clear-code.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

module Grntest
  class ExecutionContext
    attr_writer :logging
    attr_accessor :base_directory, :temporary_directory_path, :db_path
    attr_accessor :groonga_suggest_create_dataset
    attr_accessor :result
    attr_accessor :output_type
    attr_accessor :on_error
    attr_accessor :abort_tag
    def initialize
      @logging = true
      @base_directory = Pathname(".")
      @temporary_directory_path = Pathname("tmp")
      @db_path = Pathname("db")
      @groonga_suggest_create_dataset = "groonga-suggest-create-dataset"
      @n_nested = 0
      @result = []
      @output_type = "json"
      @log = nil
      @on_error = :default
      @abort_tag = nil
      @omitted = false
    end

    def logging?
      @logging
    end

    def execute
      @n_nested += 1
      yield
    ensure
      @n_nested -= 1
    end

    def top_level?
      @n_nested == 1
    end

    def log_path
      @temporary_directory_path + "groonga.log"
    end

    def log
      @log ||= File.open(log_path.to_s, "a+")
    end

    def relative_db_path
      @db_path.relative_path_from(@temporary_directory_path)
    end

    def omitted?
      @omitted
    end

    def error
      case @on_error
      when :omit
        omit
      end
    end

    def omit
      @omitted = true
      abort
    end

    def abort
      throw @abort_tag
    end
  end
end
