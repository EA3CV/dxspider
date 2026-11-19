#!/usr/bin/perl
#
# This module impliments the verification routines
#
# Copyright (c) 2002 Dirk Koopman G1TLH
#
#
# 

use strict;

package Verify;

use DXUtil;
use DXDebug;
use Digest::SHA qw(sha1_base64);

sub new
{
	my $class = shift;
	my $self = bless {}, ref($class) || $class; 
	if (@_) {
		$self->newseed(@_);
		$self->newsalt;
	}
	return $self;
}

sub newseed
{
	my $self = shift;
	return $self->{seed} = sha1_base64('RbG4tST2dYPWnh6bfAaq7pPSL04', @_);
}

sub newsalt
{
	my $self = shift;
	return $self->{salt} = substr sha1_base64($self->{seed}, rand, rand, rand), 0, 6;
}

sub challenge
{
	my $self = shift;
	return $self->{salt} . sha1_base64($self->{salt}, $self->{seed}, @_);
}

sub verify
{
	my $self = shift;
	my $answer = shift;
	my $p = sha1_base64($self->{salt}, $self->{seed}, @_);
	return $p eq $answer;
}

sub seed
{
	my $self = shift;
	return @_ ? $self->{seed} = shift : $self->{seed};
}

sub salt
{
	my $self = shift;
	return @_ ? $self->{salt} = shift : $self->{salt};
}
1;
