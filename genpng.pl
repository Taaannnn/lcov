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
# genpng.pl
#
#   This script creates an overview PNG image of a source code file by
#   representing each source code character by a single pixel.
#
#   Note that the PERL module GD.pm is required for this script to work.
#   It may be obtained from http://www.cpan.org
#
# History:
#   2002-08-26: created by Peter Oberparleiter <Peter.Oberparleiter@de.ibm.com>
#

use strict;
use File::Basename; 
use Getopt::Long;


# Constants
our $genpng_version	= "genpng version 1.0";
our $url		= "http://ltp.sourceforge.net/lcov.php";


# Prototypes
sub gen_png($$$@);
sub check_and_load_module($);
sub genpng_print_usage(*);
sub genpng_process_file($$$$);


#
# Code entry point
#

# Check whether required module GD.pm is installed
if (check_and_load_module("GD"))
{
	# Note: cannot use die() to print this message because inserting this
	# code into another scrip via do() would not fail as required!
	print(STDERR <<END_OF_TEXT)
ERROR: required module GD.pm not found on this system (see www.cpan.org).
END_OF_TEXT
	;
	exit(2);
}

# Check whether we're called from the command line or from another script
if (!caller)
{
	my $filename;
	my $tab_size = 4;
	my $width = 80;
	my $out_filename;
	my $help;
	my $version;

	# Parse command line options
	if (!GetOptions("tab-size=i" => \$tab_size,
			"width=i" => \$width,
			"output-filename=s" => \$out_filename,
			"help" => \$help,
			"version" => \$version))
	{
		genpng_print_usage(*STDERR);
		exit(1);
	}

	$filename = $ARGV[0];

	# Check for help flag
	if ($help)
	{
		genpng_print_usage(*STDOUT);
		exit(0);
	}

	# Check for version flag
	if ($version)
	{
		print("$genpng_version\n");
		exit(0);
	}

	# Check options
	if (!$filename)
	{
		print(STDERR "No filename specified\n");
		genpng_print_usage(*STDOUT);
		exit(1);
	}

	# Check for output filename
	if (!$out_filename)
	{
		$out_filename = "$filename.png";
	}

	genpng_process_file($filename, $out_filename, $width, " "x$tab_size);
	exit(0);
}


#
# genpng_print_usage(handle)
#
# Write out command line usage information to given filehandle.
#

sub genpng_print_usage(*)
{
	local *HANDLE = $_[0];
	my $tool_name = basename($0);

	print(HANDLE <<END_OF_USAGE)
Usage: $tool_name [OPTIONS] SOURCEFILE

Create an overview image for a given source code file of either plain text
or .gcov file format.

  -h, --help                        Print this help, then exit
  -v, --version                     Print version number, then exit
  -t, --tab-size TABSIZE            Use TABSIZE spaces in place of tab
  -w, --width WIDTH                 Set width of output image to WIDTH pixel
  -o, --output-filename FILENAME    Write image to FILENAME

See $url for more information on this tool.
END_OF_USAGE
	;
}


#
# check_and_load_module(module_name)
#
# Check whether a module by the given name is installed on this system
# and make it known to the interpreter if available. Return undefined if it
# is installed, an error message otherwise.
#

sub check_and_load_module($)
{
	eval("use $_[0];");
	return $@;
}


#
# genpng_process_file(filename, out_filename, width, tab_spaces)
#

sub genpng_process_file($$$$)
{
	my $filename		= $_[0];
	my $out_filename	= $_[1];
	my $width		= $_[2];
	my $tab_spaces		= $_[3];
	local *HANDLE;
	my @source;

	open(HANDLE, "<$filename")
		or die("ERROR: cannot open $filename!\n");

	# Check for .gcov filename extension
	if ($filename =~ /^(.*).gcov$/)
	{
		# Assume gcov text format
		while (<HANDLE>)
		{
			if (/^\t\t(.*)$/)
			{
				# Uninstrumented line
				push(@source, ":$1");
			}
			elsif (/^      ######    (.*)$/)
			{
				# Line with zero execution count
				push(@source, "0:$1");
			}
			elsif (/^( *)(\d*)    (.*)$/)
			{
				# Line with positive execution count
				push(@source, "$2:$3");
			}
		}
	}
	else
	{
		# Plain text file
		while (<HANDLE>) { push(@source, ":$_"); }
	}
	close(HANDLE);

	gen_png($out_filename, $width, $tab_spaces, @source);
}


#
# gen_png(filename, width, tab_spaces, source)
#
# Write an overview PNG file to FILENAME. Source code is defined by SOURCE
# which is a list of lines <count>:<source code> per source code line.
# The output image will be made up of one pixel per character of source,
# coloring will be done according to execution counts. WIDTH defines the
# image width. TAB_SPACES specifies the replacement string for tabulator
# signs in source code text.
#
# Die on error.
#

sub gen_png($$$@)
{
	my $filename = shift(@_);	# Filename for PNG file
	my $overview_width = shift(@_);	# Imagewidth for image
	my $tab_spaces = shift(@_);	# Replacement string for tab signs
	my @source = @_;	# Source code as passed via argument 2
	my $height = scalar(@source);	# Height as define by source size
	my $overview;		# Source code overview image data
	my $col_plain_back;	# Color for overview background
	my $col_plain_text;	# Color for uninstrumented text
	my $col_cov_back;	# Color for background of covered lines
	my $col_cov_text;	# Color for text of covered lines
	my $col_nocov_back;	# Color for background of lines which
				# were not covered (count == 0)
	my $col_nocov_text;	# Color for test of lines which were not
				# covered (count == 0)
	my $line;		# Current line during iteration
	my $row = 0;		# Current row number during iteration
	my $column;		# Current column number during iteration
	my $color_text;		# Current text color during iteration
	my $color_back;		# Current background color during iteration
	my $last_count;		# Count of last processed line
	my $count;		# Count of current line
	local *PNG_HANDLE;	# Handle for output PNG file

	# Create image
	$overview = new GD::Image($overview_width, $height)
		or die("ERROR: cannot allocate overview image!\n");

	# Define colors
	$col_plain_back	= $overview->colorAllocate(0xff, 0xff, 0xff);
	$col_plain_text	= $overview->colorAllocate(0xaa, 0xaa, 0xaa);
	$col_cov_back	= $overview->colorAllocate(0xaa, 0xa7, 0xef);
	$col_cov_text	= $overview->colorAllocate(0x5d, 0x5d, 0xea);
	$col_nocov_back = $overview->colorAllocate(0xff, 0x00, 0x00);
	$col_nocov_text = $overview->colorAllocate(0xaa, 0x00, 0x00);

	# Visualize each line
	foreach $line (@source)
	{
		# Replace tabs with spaces to keep consistent with source
		# code view
		$line =~ s/\t/$tab_spaces/g;

		# Skip lines which do not follow the <count>:<line>
		# specification, otherwise $1 = count, $2 = source code
		if (!($line =~ /(\d*):(.*)$/)) { next; }
		$count = $1;

		# Decide which color pair to use

		# If this line was not instrumented but the one before was,
		# take the color of that line to widen color areas in
		# resulting image
		if (($count eq "") && defined($last_count) &&
		    ($last_count ne ""))
		{
			$count = $last_count;
		}

		if ($count eq "")
		{
			# Line was not instrumented
			$color_text = $col_plain_text;
			$color_back = $col_plain_back;
		}
		elsif ($count == 0)
		{
			# Line was instrumented but not executed
			$color_text = $col_nocov_text;
			$color_back = $col_nocov_back;
		}
		else
		{
			# Line was instrumented and executed
			$color_text = $col_cov_text;
			$color_back = $col_cov_back;
		}

		# Write one pixel for each source character
		$column = 0;
		foreach (split("", $2))
		{
			# Check for width
			if ($column >= $overview_width) { last; }

			if ($_ eq " ")
			{
				# Space
				$overview->setPixel($column++, $row,
						    $color_back);
			}
			else
			{
				# Text
				$overview->setPixel($column++, $row,
						    $color_text);
			}
		}

		# Fill rest of line		
		while ($column < $overview_width)
		{
			$overview->setPixel($column++, $row, $color_back);
		}

		$last_count = $1;

		$row++;
	}

	# Write PNG file
	open (PNG_HANDLE, ">$filename")
		or die("ERROR: cannot write png file $filename!\n");
	binmode(*PNG_HANDLE);
	print(PNG_HANDLE $overview->png());
	close(PNG_HANDLE);
}