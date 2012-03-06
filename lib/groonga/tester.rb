#!/usr/bin/env ruby
#
# Copyright (C) 2012  Kouhei Sutou <kou@clear-code.com>
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

require "English"
require "optparse"
require "pathname"
require "fileutils"
require "tempfile"
require "json"
require "shellwords"

module Groonga
  class Tester
   VERSION = "1.0.0"

   class << self
     def run(argv=nil)
       argv ||= ARGV.dup
       tester = new
       catch do |tag|
         parser = create_option_parser(tester, tag)
         targets = parser.parse!(argv)
         tester.run(*targets)
       end
     end

     private
     def create_option_parser(tester, tag)
       parser = OptionParser.new
       parser.banner += " TEST_FILE_OR_DIRECTORY..."

       parser.on("--groonga=COMMAND",
                 "Use COMMAND as groonga command",
                 "(#{tester.groonga})") do |command|
         tester.groonga = command
       end

       parser.on("--groonga-suggest-create-dataset=COMMAND",
                 "Use COMMAND as groonga_suggest_create_dataset command",
                 "(#{tester.groonga_suggest_create_dataset})") do |command|
         tester.groonga_suggest_create_dataset = command
       end

       parser.on("--base-directory=DIRECTORY",
                 "Use DIRECTORY as a base directory of relative path",
                 "(#{tester.base_directory})") do |directory|
         tester.base_directory = directory
       end

       parser.on("--diff=DIFF",
                 "Use DIFF as diff command",
                 "(#{tester.diff})") do |diff|
         tester.diff = diff
         tester.diff_options.clear
       end

       diff_option_is_specified = false
       parser.on("--diff-option=OPTION",
                 "Use OPTION as diff command",
                 "(#{tester.diff_options.join(' ')})") do |option|
         tester.diff_options.clear if diff_option_is_specified
         tester.diff_options << option
         diff_option_is_specified = true
       end

       parser.on("--version",
                 "Show version and exit") do
         puts(GroongaTester::VERSION)
         throw(tag, true)
       end

       parser
     end
   end

   attr_accessor :groonga, :groonga_suggest_create_dataset
   attr_accessor :base_directory, :diff, :diff_options
   def initialize
     @groonga = "groonga"
     @groonga_suggest_create_dataset = "groonga-suggest-create-dataset"
     @base_directory = "."
     detect_suitable_diff
   end

   def run(*targets)
     succeeded = true
     return succeeded if targets.empty?

     reporter = Reporter.new(self)
     reporter.start
     targets.each do |target|
       target_path = Pathname(target)
       next unless target_path.exist?
       if target_path.directory?
         Dir.glob(target_path + "**" + "*.test") do |target_file|
           succeeded = false unless run_test(Pathname(target_file), reporter)
         end
       else
         succeeded = false unless run_test(target_path, reporter)
       end
     end
     reporter.finish
     succeeded
   end

   private
   def run_test(test_script_path, reporter)
     runner = Runner.new(self, test_script_path)
     runner.run(reporter)
   end

   def detect_suitable_diff
     if command_exist?("cut-diff")
       @diff = "cut-diff"
       @diff_options = ["--context-lines", "10"]
     else
       @diff = "diff"
       @diff_options = ["-u"]
     end
   end

   def command_exist?(name)
     ENV["PATH"].split(File::PATH_SEPARATOR).each do |path|
       absolute_path = File.join(path, name)
       return true if File.executable?(absolute_path)
     end
     false
   end

   class Runner
     MAX_N_COLUMNS = 79

     def initialize(tester, test_script_path)
       @tester = tester
       @test_script_path = test_script_path
       @max_n_columns = MAX_N_COLUMNS
     end

     def run(reporter)
       succeeded = true

       reporter.start_test(@test_script_path)
       actual_result = run_groonga_script
       actual_result = normalize_result(actual_result)
       expected_result = read_expected_result
       if expected_result
         if actual_result == expected_result
           reporter.pass_test
           remove_reject_file
         else
           reporter.fail_test(expected_result, actual_result)
           output_reject_file(actual_result)
           succeeded = false
         end
       else
         reporter.no_check_test(actual_result)
         output_actual_file(actual_result)
       end
       reporter.finish_test

       succeeded
     end

     private
     def run_groonga_script
       create_temporary_directory do |directory_path|
         run_groonga(File.join(directory_path, "db")) do |io|
           context = Executer::Context.new
           context.base_directory = @tester.base_directory
           executer = Executer.new(io, context)
           executer.execute(@test_script_path)
         end
       end
     end

     def create_temporary_directory
       path = "tmp"
       FileUtils.rm_rf(path)
       FileUtils.mkdir_p(path)
       begin
         yield path
       ensure
         FileUtils.rm_rf(path)
       end
     end

     def run_groonga(db_path)
       IO.popen([@tester.groonga, "-n", db_path], "r+") do |io|
         begin
           yield io
         ensure
           io.close unless io.closed?
         end
       end
     end

     def normalize_result(result)
       normalized_result = ""
       result.each do |tag, content, options|
         case tag
         when :input
           normalized_result << content
         when :output
           case options[:format]
           when "json"
             status, *values = JSON.parse(content)
             normalized_status = normalize_status(status)
             normalized_output_content = [normalized_status, *values]
             normalized_output = JSON.generate(normalized_output_content)
             if normalized_output.bytesize > @max_n_columns
               normalized_output = JSON.pretty_generate(normalized_output_content)
             end
             normalized_output.force_encoding("ASCII-8BIT")
             normalized_result << "#{normalized_output}\n"
           else
             normalized_result << "#{content}\n".force_encoding("ASCII-8BIT")
           end
         when :error
           normalized_result << "#{content}\n".force_encoding("ASCII-8BIT")
         end
       end
       normalized_result
     end

     def normalize_status(status)
       return_code, started_time, elapsed_time, *rest = status
       if return_code.zero?
         [0, 0.0, 0.0]
       else
         message, backtrace = rest
         [[return_code, 0.0, 0.0], message]
       end
     end

     def have_extension?
       not @test_script_path.extname.empty?
     end

     def related_file_path(extension)
       path = Pathname(@test_script_path.to_s.gsub(/\.[^.]+\z/, ".#{extension}"))
       return nil if @test_script_path == path
       path
     end

     def read_expected_result
       return nil unless have_extension?
       result_path = related_file_path("expected")
       return nil if result_path.nil?
       return nil unless result_path.exist?
       result_path.open("r:ascii-8bit") do |result_file|
         result_file.read
       end
     end

     def remove_reject_file
       return unless have_extension?
       reject_path = related_file_path("reject")
       return if reject_path.nil?
       FileUtils.rm_rf(reject_path.to_s)
     end

     def output_reject_file(actual_result)
       output_actual_result(actual_result, "reject")
     end

     def output_actual_file(actual_result)
       output_actual_result(actual_result, "actual")
     end

     def output_actual_result(actual_result, suffix)
       result_path = related_file_path(suffix)
       return if result_path.nil?
       result_path.open("w:ascii-8bit") do |result_file|
         result_file.print(actual_result)
       end
     end
   end

   class Executer
     class Context
       attr_accessor :logging, :base_directory, :result
       def initialize
         @logging = true
         @base_directory = "."
         @n_nested = 0
         @result = []
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
     end

     class Error < StandardError
     end

     class NotExist < Error
       attr_reader :path
       def initialize(path)
         @path = path
         super("<#{path}> doesn't exist.")
       end
     end

     def initialize(groonga, context=nil)
       @groonga = groonga
       @loading = false
       @pending_command = ""
       @current_command_name = nil
       @output_format = nil
       @context = context || Context.new
     end

     def execute(script_path)
       unless script_path.exist?
         raise NotExist.new(script_path)
       end

       @context.execute do
         script_path.open("r:ascii-8bit") do |script_file|
           script_file.each_line do |line|
             begin
               if @loading
                 execute_line_on_loading(line)
               else
                 execute_line_with_continuation_line_support(line)
               end
             rescue Error
               line_info = "#{script_path}:#{script_file.lineno}:#{line.chomp}"
               log_error("#{line_info}: #{$!.message}")
               raise unless @context.top_level?
             end
           end
         end
       end

       @context.result
     end

     private
     def execute_line_on_loading(line)
       log_input(line)
       @groonga.print(line)
       @groonga.flush
       if /\]$/ =~ line
         current_result = read_output
         unless current_result.empty?
           @loading = false
           log_output(current_result)
         end
       end
     end

     def execute_line_with_continuation_line_support(line)
       if /\\$/ =~ line
         @pending_command << $PREMATCH
       else
         if @pending_command.empty?
           execute_line(line)
         else
           @pending_command << line
           execute_line(@pending_command)
           @pending_command = ""
         end
       end
     end

     def execute_line(line)
       case line
       when /\A\s*\z/
         # do nothing
       when /\A\s*\#/
         comment_content = $POSTMATCH
         execute_comment(comment_content)
       else
         execute_command(line)
       end
     end

     def execute_comment(content)
       case content.strip
       when "disable-logging"
         @context.logging = false
       when "enable-logging"
         @context.logging = true
       when /\Ainclude\s+/
         path = $POSTMATCH.strip
         return if path.empty?
         execute_script(path)
       end
     end

     def execute_script(path)
       executer = self.class.new(@groonga, @context)
       script_path = Pathname(path)
       if script_path.relative?
         script_path = Pathname(@context.base_directory) + script_path
       end
       executer.execute(script_path)
     end

     def execute_command(line)
       extract_command_info(line)
       @loading = true if @current_command == "load"
       log_input(line)
       @groonga.print(line)
       @groonga.flush
       unless @loading
         log_output(read_output)
       end
     end

     def extract_command_info(line)
       words = Shellwords.split(line)
       @current_command = words.shift
       if @current_command == "dump"
         @output_format = "groonga-command"
       else
         @output_format = "json"
         words.each_with_index do |word, i|
           if /\A--output_format(?:=(.+))?\z/ =~ word
             @output_format = $1 || words[i + 1]
             break
           end
         end
       end
     end

     def read_output
       output = ""
       first_timeout = 1
       timeout = first_timeout
       while IO.select([@groonga], [], [], timeout)
         break if @groonga.eof?
         output << @groonga.readpartial(65535)
         timeout = 0
       end
       output
     end

     def log(tag, content, options={})
       return unless @context.logging
       return if content.empty?
       log_force(tag, content, options)
     end

     def log_force(tag, content, options)
       @context.result << [tag, content, options]
     end

     def log_input(content)
       log(:input, content)
     end

     def log_output(content)
       log(:output, content,
           :command => @current_command,
           :format => @output_format)
     end

     def log_error(content)
       log_force(:error, content)
     end
   end

   class Reporter
     def initialize(tester)
       @tester = tester
       @term_width = guess_term_width
       @current_column = 0
       @output = STDOUT
       @n_tests = 0
       @n_passed_tests = 0
       @failed_tests = []
     end

     def start
     end

     def start_test(test_script_path)
       @test_name = test_script_path.basename
       print("  #{@test_name}")
       @output.flush
     end

     def pass_test
       report_test_result("pass")
       @n_passed_tests += 1
     end

     def fail_test(expected, actual)
       report_test_result("fail")
       puts("=" * @term_width)
       report_diff(expected, actual)
       puts("=" * @term_width)
       @failed_tests << @test_name
     end

     def no_check_test(result)
       report_test_result("not checked")
       puts(result)
     end

     def finish_test
       @n_tests += 1
     end

     def finish
       puts
       puts("#{@n_tests} tests, " +
            "#{@n_passed_tests} passes, " +
            "#{@failed_tests.size} failures.")
       if @n_tests.zero?
         pass_ratio = 0
       else
         pass_ratio = (@n_passed_tests / @n_tests.to_f) * 100
       end
       puts("%.4g%% passed." % pass_ratio)
     end

     private
     def print(message)
       @current_column += message.to_s.size
       @output.print(message)
     end

     def puts(*messages)
       @current_column = 0
       @output.puts(*messages)
     end

     def report_test_result(label)
       message = " [#{label}]"
       message = message.rjust(@term_width - @current_column) if @term_width > 0
       puts(message)
     end

     def report_diff(expected, actual)
       create_temporary_file("expected", expected) do |expected_file|
         create_temporary_file("actual", actual) do |actual_file|
           diff_options = @tester.diff_options.dup
           diff_options.concat(["--label", "(actual)", actual_file.path,
                                "--label", "(expected)", expected_file.path])
           system(@tester.diff, *diff_options)
         end
       end
     end

     def create_temporary_file(key, content)
       file = Tempfile.new("groonga-test-#{key}")
       file.print(content)
       file.close
       yield file
     end

     def guess_term_width
       Integer(ENV["COLUMNS"] || ENV["TERM_WIDTH"] || 79)
     rescue ArgumentError
       0
     end
   end
 end
end