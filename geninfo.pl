#!/usr/bin/perl -w
#
#   Copyright (c) International Business Machines  Corp., 2002
#
#   This program is free software;  you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or (at
#   your option) any later version.
#
#   This program is distributed in the hope that it will be useful, but
#   WITHOUT ANY WARRANTY;  without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#   General Public License for more details.                 
#
#   You should have received a copy of the GNU General Public License
#   along with this program;  if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
#
# geninfo.pl
#
#   This script generates .info files from .da files as created by code
#   instrumented with gcc's built-in profiling mechanism. Call it with --help
#   to get information on available options.
#
#
# Authors:
#   2002-08-23 created by Peter Oberparleiter <Peter.Oberparleiter@de.ibm.com>
#                         IBM Lab Boeblingen
#        based on code by Manoj Iyer <manjo@mail.utexas.edu> and
#                         Megan Bock <mbock@us.ibm.com>
#                         IBM Austin
#   2002-09-05 / Peter Oberparleiter: implemented option that allows file list
#

use strict;
use File::Basename; 
use Getopt::Long;


# Constants
our $version_info = "geninfo version 1.0";
our $url	  = "http://ltp.sourceforge.net/lcov.php";


# Prototypes
sub print_usage(*);
sub gen_info($);
sub process_dafile($);
sub match_filename($@);
sub split_filename($);
sub get_absolute_path($$);
sub get_dir($);
sub normalize_path($);
sub read_gcov_file($);
sub read_bb_file($);
sub read_string(*$);
sub unpack_int32($);
sub info(@);

# Global variables
our @data_directory;
our $test_name = "";
our $quiet;
our $help;
our $output_filename;
our $version;

our $cwd = `pwd`;
chomp($cwd);


#
# Code entry point
#

# Register handler routine to be called when interrupted
$SIG{"INT"} = \&int_handler;

# Parse command line options
if (!GetOptions("test-name=s" => \$test_name,
		"output-filename=s" => \$output_filename,
		"version" =>\$version,
		"quiet" => \$quiet,
		"help" => \$help
		))
{
	print_usage(*STDERR);
	exit(1);
}

@data_directory = @ARGV;

# Check for help option
if ($help)
{
	print_usage(*STDOUT);
	exit(0);
}

# Check for version option
if ($version)
{
	print($version_info."\n");
	exit(0);
}

# Check for directory name
if (!@data_directory)
{
	print(STDERR "No directory specified\n");
	print_usage(*STDERR);
	exit(1);
}
else
{
	foreach (@data_directory)
	{
		stat($_);
		if (!-r _)
		{
			die("ERROR: cannot read $_!\n");
		}
	}
}

# Check output filename
if ($output_filename)
{
	if ($output_filename eq "-")
	{
		# Turn of progress messages because STDOUT is needed for
		# data output
		$quiet = 1;
	}
	else
	{
		# Initially create output filename, data is appended
		# for each .da file processed
		local *DUMMY_HANDLE;
		open(DUMMY_HANDLE, ">$output_filename")
			or die("ERROR: cannot create $output_filename!\n");
		close(DUMMY_HANDLE);

		# Make $output_filename an absolute path because we're going
		# to change directories while processing files
		if (!($output_filename =~ /^\/(.*)$/))
		{
			$output_filename = $cwd."/".$output_filename;
		}
	}
}

# Do something
foreach (@data_directory)
{
	gen_info($_);
}
info("Finished .info-file creation\n");

exit(0);



#
# print_usage(handle)
#
# Print usage information.
#

sub print_usage(*)
{
	local *HANDLE = $_[0];
	my $tool_name = basename($0);

	print(HANDLE <<END_OF_USAGE);
Usage: $tool_name [OPTIONS] DIRECTORY

Traverse DIRECTORY and create a .info file for each .da file found. Note that
you may specify more than one directory, all of which are then processed
sequentially.

  -h, --help                        Print this help, then exit
  -v, --version                     Print version number, then exit
  -q, --quiet                       Do not print progress messages
  -t, --test-name NAME              Use test case name NAME for resulting data
  -o, --output-filename OUTFILE     Write data only to OUTFILE

See $url for more information on this tool.
END_OF_USAGE
	;
}


#
# gen_info(directory)
#
# Traverse DIRECTORY and create a .info file for each .da file found.
# The .info file contains TEST_NAME in the following format:
#
#   TN:<test name>
#
# For each source file name referenced in the .da file, there is a section
# containing source code and coverage data:
#
#   SF:<absolute path to the source file>
#   FN:<line number of function start>,<function name> for each function
#   DA:<line number>,<execution count> for each instrumented line
#   LH:<number of lines with an execution count> greater than 0
#   LF:<number of instrumented lines>
#
# Sections are separated by:
#
#   end_of_record
#
# In addition to the main source code file there are sections for each
# #included file containing executable code. Note that the absolute path
# of a source file is generated by interpreting the contents of the respective
# .bb file. Relative filenames are prepended with the directory in which the
# .bb file is found. Note also that symbolic links to the .bb file will be
# resolved so that the actual file path is used instead of the path to a link.
# This approach is necessary for the mechanism to work with the /proc/gcov
# files.
#
# Die on error.
#

sub gen_info($)
{
	my $directory = $_[0];
	my @file_list;
	info("Scanning $directory for .da files ...\n");	

	@file_list = `find $directory -follow -name \\*.da -type f 2>/dev/null`;
	chomp(@file_list);
	@file_list or die("ERROR: No .da files found in $directory!\n");

	info("Found %d data files in %s\n", $#file_list+1, $directory);

	# Process all files in list
	foreach (@file_list) { process_dafile($_); }
}


#
# process_dafile(da_filename)
#
# Create a .info file for a single .da file.
#
# Die on error.
#

sub process_dafile($)
{
	info("Processing %s\n", $_[0]);

	my $da_filename;	# Name of .da file to process
	my $da_dir;		# Directory of .da file
	my $da_basename;	# .da filename without ".da" extension
	my $bb_filename;	# Name of respective .bb file
	my %bb_content;		# Contents of .bb file
	my $gcov_error;		# Error code of gcov tool
	my $object_dir;		# Directory containing all object files
	my $source_filename;	# Name of a source code file
	my $gcov_file;		# Name of a .gcov file
	my @gcov_content;	# Content of a .gcov file
	my @gcov_list;		# List of generated .gcov files
	my $line_number;	# Line number count
	my $lines_hit;		# Number of instrumented lines hit
	my $lines_found;	# Number of instrumented lines found
	local *INFO_HANDLE;

	# Get path to .da file in absolute and normalized form (begins with /,
	# contains no more ../ or ./)
	$da_filename = normalize_path(get_absolute_path($_[0], $cwd));

	# Get directory and basename of .da file
	($da_dir, $da_basename) = split_filename($da_filename);

	# Check for writeable $da_dir (gcov will try to write files there)
	stat($da_dir);
	if (!-w _)
	{
		die("ERROR: cannot write to directory $da_dir!\n");
	}

	# Construct name of .bb file
	$bb_filename = $da_dir."/".$da_basename.".bb";

	# Find out the real location of .bb file in case we're just looking at
	# a link
	while (readlink($bb_filename))
	{
		$bb_filename = readlink($bb_filename);
	}

	# Read contents of .bb file into hash. We need it later to find out
	# the absolute path to each .gcov file created as well as for
	# information about functions and their source code positions.
	%bb_content = read_bb_file($bb_filename);

	# Set $object_dir to real location of object files. This may differ
	# from $da_dir if the .bb file is just a link to the "real" object
	# file location. We need to apply GCOV with using that directory to
	# ensure that all relative #include-files are found as well.
	($object_dir) = split_filename($bb_filename);

	# Is the .da file in the same directory with all the other files?
	if ($object_dir ne $da_dir)
	{
		# Need to create link to .da file in $object_dir
		system("ln -s $da_filename $object_dir/$da_basename.da")
			and die ("ERROR: cannot create link $object_dir/".
				 "$da_basename.da!\n");
	}

	# Change to directory containing .da files and apply GCOV
	chdir($da_dir);
	undef($!);
	system("gcov $da_basename.c -o $object_dir >/dev/null");
	$gcov_error = $!;

	# Clean up link
	if ($object_dir ne $da_dir)
	{
		unlink($object_dir."/".$da_basename.".da");
	}

	$gcov_error and die("ERROR: GCOV failed for $da_filename!\n");

	# Collect data from resulting .gcov files and create .info file
	@gcov_list = glob("*.gcov");

	# Check for files
	if (!@gcov_list)
	{
		warn("WARNING: gcov did not create any files for ".
		     "$da_filename!\n");
	}

	# Check whether we're writing to a single file
	if ($output_filename)
	{
		if ($output_filename eq "-")
		{
			*INFO_HANDLE = *STDOUT;
		}
		else
		{
			# Append to output file
			open(INFO_HANDLE, ">>$output_filename")
				or die("ERROR: cannot write to ".
				       "$output_filename!\n");
		}
	}
	else
	{
		# Open .info file for output
		open(INFO_HANDLE, ">$da_filename.info")
			or die("ERROR: cannot create $da_filename.info!\n");
	}

	# Write test name
	printf(INFO_HANDLE "TN:%s\n", $test_name);

	# Traverse the list of generated .gcov files and combine them into a
	# single .info file
	foreach $gcov_file (@gcov_list)
	{
		$source_filename =
			match_filename($gcov_file, keys(%bb_content));

		# Skip files that are not mentioned in the .bb file
		if (!$source_filename)
		{
			warn("WARNING: cannot find an entry for ".
			     $gcov_file." in .bb file, skipping file!");
			unlink($gcov_file);
			next;
		}

		@gcov_content = read_gcov_file($gcov_file);

		# Skip empty files
		if (!@gcov_content)
		{
			warn("WARNING: skipping empty file ".$gcov_file);
			unlink($gcov_file);
			next;
		}

		# Write absolute path of source file
		printf(INFO_HANDLE "SF:%s\n", $source_filename);

		# Write function-related information
		foreach (split(",",$bb_content{$source_filename}))
		{
			# Write "line_number,function_name" for each function.
			# Note that $_ contains this information in the form
			# "function_name=line_number" so that the order of
			# elements has to be reversed.
			printf(INFO_HANDLE "FN:%s\n",
			       join(",", (split("=", $_))[1,0]));
		}

		# Reset line counters
		$line_number = 0;
		$lines_found = 0;
		$lines_hit = 0;

		# Write coverage information for each instrumented line
		# Note: @gcov_content contains a list of (flag, count, source)
		# tuples for each source code line
		while (@gcov_content)
		{
			$line_number++;

			# Check for instrumented line
			if ($gcov_content[0])
			{
				$lines_found++;
				printf(INFO_HANDLE "DA:%s,%s\n",
				       $line_number, $gcov_content[1]);

				# Increase $lines_hit in case of an execution
				# count>0
				if ($gcov_content[1] > 0) { $lines_hit++; }
			}

			# Remove already processed data from array
			splice(@gcov_content,0,3);
		}

		# Write line statistics and section separator
		printf(INFO_HANDLE "LF:%s\n", $lines_found);
		printf(INFO_HANDLE "LH:%s\n", $lines_hit);
		print(INFO_HANDLE "end_of_record\n");

		# Remove .gcov file after processing
		unlink($gcov_file);
	}

	if (!($output_filename && ($output_filename eq "-")))
	{
		close(INFO_HANDLE);
	}

	# Change back to initial directory
	chdir($cwd);
}


#
# match_filename(gcov_filename, list)
#
# Return the absolute path to the source code file corresponding to the given
# GCOV_FILENAME by matching the basename part with the LIST of absolute paths
# extracted from the .bb file.
#

sub match_filename($@)
{
	# Get path components of first argument and remove it so that @_
	# refers to the LIST argument
	my @gcov_components = split_filename(shift);

	foreach (@_)
	{
		if (join(".", (split_filename($_))[1, 2]) eq
		    $gcov_components[1])
		{
			return($_);
		}
	}

	return("");
}


#
# split_filename(filename)
#
# Return (path, filename, extension) for a given FILENAME.
#

sub split_filename($)
{
	my @path_components = split('/', $_[0]);
	my @file_components = split('\.', pop(@path_components));
	my $extension = pop(@file_components);

	return (join("/",@path_components), join(".",@file_components),
		$extension);
}


#
# get_absolute_path(filename, path)
#
# Return FILENAME as absolute path where PATH is used as parent directory if
# FILENAME is not already absolute.
#

sub get_absolute_path($$)
{
	if (substr($_[0], 0, 1) eq "/") { return($_[0]); }

	return($_[1]."/".$_[0]);
}


#
# get_dir(filename);
#
# Return the directory component of a given FILENAME.
#

sub get_dir($)
{
	my @components = split("/", $_[0]);
	pop(@components);

	return join("/", @components);
}


#
# normalize_path(path)
#
# Return the normalized form of the provided PATH. Normalization includes:
#
#     1) removal of trailing '/'s
#     2) removal of adjacent '//'s
#     3) removal of './'
#     4) removal of '../' if possible
#

sub normalize_path($)
{
	my @components = split("/", $_[0]);
	my $absolute = !$components[0];
	my $i;

	for ($i=0; $i<scalar(@components); $i++)
	{
		# Check for //s and ./s
		if (!$components[$i] or $components[$i] eq ".")
		{
			# Remove
			splice(@components,$i,1);
			$i--;
		}
		elsif ($components[$i] eq "..")
		{
			# Found ../, check for beginning of path
			if ($i>0)
			{
				# Check whether parent component was an
				# unresolvable ../
				if ($components[$i-1] ne "..")
				{
					# Remove ../ and previous component
					splice(@components,$i-1,2);
					$i-=2;
				}
			}
			else
			{
				# ../s at beginning of path may only be
				# removed when this is an absolute path
				if ($absolute)
				{
					splice(@components,$i,1);
					$i--;
				}
			}
		}
	}

	return(($absolute ? "/" : "").join("/",@components));
}


#
# read_gcov_file(gcov_filename)
#
# Parse file GCOV_FILENAME (.gcov file format) and return a list of 3 elements
# (flag, count, source) for each source code line:
#
# $result[($line_number-1)*3+0] = instrumentation flag for line $line_number
# $result[($line_number-1)*3+1] = execution count for line $line_number
# $result[($line_number-1)*3+2] = source code text for line $line_number
#
# Die on error.
#

sub read_gcov_file($)
{
	my @result = ();
	my $number;

	open(INPUT, $_[0])
		or die("ERROR: cannot read $_[0]!\n");

	while (<INPUT>)
	{
		chomp($_);
		
		# Leading chars of a line are either two tabs or the execution
		# count
		if (substr($_,0,2) eq "\t\t")
		{
			# Lines without counts are not instrumented
			push(@result,0);
			push(@result,0);
			push(@result,substr($_,2));
		}
		else
		{
			# Get actual number and remove blanks from either side
			$number = (split(" ",substr($_, 0, 16)))[0];

			# Check for zero count which is indicated by ######
			if ($number eq "######") { $number = 0;	}

			push(@result,1);
			push(@result,$number);
			push(@result,substr($_,16));
		}
	}

	close(INPUT);
	return(@result);
}


#
# read_bb_file(bb_filename)
#
# Read .bb file BB_FILENAME and return a hash containing the following
# mapping:
#
#   filename -> comma-separated list of pairs (function name=starting
#               line number) for each function found
#
# for each entry in the .bb file. Filenames are absolute, i.e. relative
# filenames are prepended with bb_filename's path component.
#
# Die on error.
#

sub read_bb_file($)
{
	my $bb_filename		= $_[0];
	my %result;
	my $filename;
	my $function_name;
	my $cwd			= `pwd`;
	chomp($cwd);
	my $base_dir		= get_dir(normalize_path(get_absolute_path(
							$bb_filename, $cwd)));
	my $minus_one		= sprintf("%d",0x80000001);
	my $minus_two		= sprintf("%d",0x80000002);
	my $value;
	my $packed_word;
	local *INPUT;

	open(INPUT, $bb_filename)
		or die("ERROR: cannot read $bb_filename!\n");

	binmode(INPUT);

	# Read data in words of 4 bytes
	while (read(INPUT, $packed_word, 4) == 4)
	{
		# Decode integer in intel byteorder
		$value = unpack_int32($packed_word);

		# Note: the .bb file format is documented in GCC info pages
		if ($value == $minus_one)
		{
			# Filename follows
			$filename = read_string(*INPUT, $minus_one)
				    or die("ERROR: incomplete filename in ".
					    "$bb_filename!\n");

			# Make path absolute
			$filename = normalize_path(get_absolute_path(
					$filename, $base_dir));

			# Insert into hash if not yet present.
			# This is necessary because functions declared as
			# "inline" are not listed as actual functions in
			# .bb file
			if (!$result{$filename})
			{
				$result{$filename}="";
			}
		}
		elsif ($value == $minus_two)
		{
			# Function name follows
			$function_name = read_string(*INPUT, $minus_two)
				 or die("ERROR: incomplete function ".
					"name in $bb_filename!\n");
		}
		elsif ($value > 0)
		{
			if ($function_name)
			{
				# Got a full entry filename, funcname, lineno
				# Add to resulting hash

				$result{$filename}.=
				  ($result{$filename} ? "," : "").
				  join("=",($function_name,$value));
				undef($function_name);
			}
		}
	}
	close(INPUT);

	if (!scalar(keys(%result)))
	{
		die("ERROR: no data found in $bb_filename!\n");
	}
	return %result;
}


#
# read_string(handle, delimiter);
#
# Read and return a string in 4-byte chunks from HANDLE until DELIMITER
# is found.
#
# Return empty string on error.
#

sub read_string(*$)
{
	my $HANDLE	= $_[0];
	my $delimiter	= $_[1];
	my $string	= "";
	my $packed_word;
	my $value;

	while (read($HANDLE,$packed_word,4) == 4)
	{
		$value = unpack_int32($packed_word);

		if ($value == $delimiter)
		{
			# Remove trailing nil bytes
			$/="\0";
			while (chomp($string)) {};
			$/="\n";
			return($string);
		}

		$string = $string.$packed_word;
	}
	return("");
}


#
# unpack_int32(word)
#
# Interpret 4-byte string WORD as signed 32 bit integer in
# little endian encoding and return its value.
#

sub unpack_int32($)
{
	return sprintf("%d", unpack("V",$_[0]));
}


#
# info(printf_parameter)
#
# Use printf to write PRINTF_PARAMETER to stdout only when the $quiet flag
# is not set.
#

sub info(@)
{
	if (!$quiet)
	{
		# Print info string
		printf(@_);
	}
}


#
# int_handler()
#
# Called when the script was interrupted by an INT signal (e.g. CTRl-C)
#

sub int_handler()
{
	if ($cwd) { chdir($cwd); }
	info("Aborted.\n");
	exit(1);
}
