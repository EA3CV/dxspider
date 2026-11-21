#
# this is the file which defines all the bands that are allowed in the system
#
# each entry can contain an arbitrary no of entries.
#
# an entry can have an arbitrary no of PAIRS of frequencies,
# these pairs attach themselves to the labels you provide, they are
# independant of any other pair, they can overlap, cross etc.
#
# There MUST be at least a 'band' entry
#
# It is up to YOU to make sure that it makes sense!
#
# ALL the labels MUST BE in lower case.
#
# Band names change (or I got them wrong in the first place), DO NOT CHANGE THE BAND NAMES
# THAT I USED. If you do then expect to get complaints. Instead just alias them to what
# you think they should be in the section below %bands.
#
# WARNING: if aliasing, the band alias must be declared AFTER the original.
#
# See '550khz' and '630m' as an exemplar.
#


%bands = (
                  '73khz' => bless ( { band => [71, 75],
                                                         }, 'Bands'),

                  '136khz' => bless ( { band => [135, 138],
                                                          }, 'Bands'),

                  '500khz' => bless ( { band => [472, 479],
                                                          }, 'Bands'),

                  '160m' => bless( { band => [ 1800, 2000 ],
                                                         cw => [ 1800, 1840 ],
                                                         rtty => [ 1838, 1841 ],
                                                         data => [ 1838, 1843],
                                                         ft8 => [ 1840, 1843],
                                                         ssb => [ 1831, 2000]
                                                   }, 'Bands'),

                  '80m' => bless( { band => [ 3500, 4000 ],
                                                        cw => [ 3500, 3600 ],
                                                        data => [ 3570, 3619 ],
                                                        rtty => [ 3580, 3619 ],
                                                        sstv => [ 3730, 3740 ],
                                                        ft8 => [ 3573, 3576 ],
                                                        ft4 => [ 3575, 3578 ],
                                                        ssb => [ 3601, 4000 ]
                                                  }, 'Bands'),

                  '60m' => bless( { band => [ 5195, 5450],
# No 5 MHz general allocations below 5250 - but include German beacon on 5195. Some have access up to 5450
# Extend 5 MHz SSB to include UK allocations below 5300 and CW below 5300

                                                        ssb => [5276, 5410],
# Add cw and data
														cw => [5258, 5264, 5351, 5366],
														data => [5366, 5467]
												}, 'Bands' ),

                  '40m' => bless( { band => [ 7000, 7300 ],
                                                        cw => [ 7000, 7040 ],
                                                        data => [ 7040, 7100],
                                                        rtty => [ 7040, 7060],
                                                        ft8 => [ 7074, 7077 ],
                                                        ft4 => [ 7047, 7051 ],
                                                        ssb => [ 7080, 7300 ]
                                                  }, 'Bands'),

                  '30m' => bless( { band => [ 10100, 10150 ],
                                                        cw => [ 10100, 10130 ],
                                                        data => [ 10141, 10149, 10131, 10134, 10140, 10143 ] ,
                                                        ft8 => [ 10131, 10134 ],
                                                        ft4 => [ 10140, 10143 ],
                                                        rtty => [ 10141, 10149 ]
                                                  }, 'Bands'),

                  '20m' => bless( { band => [ 14000, 14350 ],
                                                        cw => [ 14000, 14100 ],
                                                        ssb => [ 14101, 14350 ],
# Modify range
                                                        beacon => [ 14099, 14101 ],
                                                        sstv => [ 14225, 14235 ],
							              ft8 => [ 14074, 14077 ],
                                                        ft4 => [ 14080, 14083 ],
                                                        data => [ 14070, 14098, 14101, 14111 ],
                                                        rtty => [ 14070, 14098, 14101, 14111 ]
                                                  }, 'Bands'),

                  '17m' => bless( { band => [ 18068, 18168 ],
                                                        cw => [ 18068, 18100 ],
                                                        ssb => [ 18111, 18168 ],
                                                        data => [ 18100, 18108],
							              ft8 => [ 18100, 18103 ],
                                                        ft4 => [ 18104, 18107 ],
                                                        rtty => [ 18101, 18108],
# Modify range
                                                        beacon => [ 18109, 18111]
                                                  }, 'Bands'),

                  '15m' => bless( { band => [ 21000, 21450 ],
                                                        cw => [ 21000, 21150 ],
                                                        data => [ 21070, 21119, 21140, 21143 ],
                                                        rtty => [ 21070, 21119 ],
                                                        ft8 => [ 21074, 21077 ],
                                                        ft4 => [ 21140, 21143 ],
                                                        ssb => [ 21151, 21450],
# Add Beacon
														beacon => [ 21149, 21151]
                                                  }, 'Bands'),

                  '12m' => bless( { band => [ 24890, 24990 ],
                                                        cw => [ 24890, 24930 ],
                                                        ssb => [ 24931, 24990],
                                                        rtty => [ 24920, 24929],
                                                        data => [ 24920, 24929, 24915, 24918 ],
                                                        ft8 => [ 24915, 24918 ],
                                                        ft4 => [ 24919, 24922 ],
# Add Beacon
														beacon => [ 24929, 24931 ]
                                                  }, 'Bands'),

                  '10m' => bless( { band => [ 28000, 29700 ],
                                                        cw => [ 28000, 28198 ],
                                                        data => [ 28050, 28149, 29200, 29299, 28180, 28183 ],
                                                        rtty => [ 28050, 28149 ],
                                                        space => [ 29200, 29300 ],
                                                        ssb => [ 28201, 29299, 29550, 29700],
                                                        ft8 => [ 28074, 28077 ],
                                                        ft4 => [ 28180, 28183 ],
# Add Beacon
														beacon => [ 28190, 28225, 28225, 28300 ]
                                                  }, 'Bands'),

                  '8m' => bless( { band => [40000, 42000],
                                                 }, 'Bands'),

                  '6m' => bless( { band => [50000, 54000],
                                                   cw => [50000, 50100],
                                                   ssb => [50100, 50400],
                                                   data => [50300, 50500],
                                                   ft8 => [ 50313, 50316 ],
                                                   ft4 => [ 50318, 50321 ],
# Add Beacon
												   beacon => [ 50000, 50100, 50400, 50500 ]
                                                 }, 'Bands'),

                  '5m' => bless( { band => [60000, 62000],
                                                 }, 'Bands'),
# 5m band General allocation in Ireland only, with Denmark and UK with beacons

                  '4m' => bless( { band => [69887, 71500],
                                                   cw => [70000, 70250],
                                                   ssb => [70100, 70250],
# Add Beacon
												   beacon => [ 70000, 70100 ]
                                                 }, 'Bands'),
# Denmark down to 69.8875. UK NoV operation up to 71.500

                  '2m' => bless( { band => [144000, 148000],
                                                   cw => [144000, 144150],
                                                   ssb => [144150, 144400],
# Add Beacon
												   beacon => [ 144400, 144490 ]
                                                 }, 'Bands'),

#Little real CW and SSB differentiation above 2m so remove CW and SSB filters

                  '220' => bless( { band => [220000, 224000],
                                                  }, 'Bands'),

                  '70cm' => bless( { band => [420000, 450000],
                                                   }, 'Bands'),

#70cm starts at 420 MHz and extends to 450 MHz in Region 2

                  '902' => bless( { band => [902000, 928000],
                                                   }, 'Bands'),

                  '23cm' => bless( { band => [ 1240000, 1300000],
                                                   }, 'Bands'),

                  '13cm' => bless( { band => [2300000, 2450000],
                                                   }, 'Bands'),

                  '9cm' => bless( { band => [3300000, 3500000],
# Add beacon and sattelite
														beacon => [ 3400800, 3400995 ],
														sat => [ 3402000, 3410000 ]
                                                  }, 'Bands'),
#9cm extends to 3500 MHz in Region 2 and starts at 3300 MHz in Region 3

                  '6cm' => bless( { band => [5650000, 5925000],
# Add data, beacon and sat
                                                        data => [ 5670000, 5700000 ],
														beacon => [ 57608000, 57609900 ],
														sat => [ 5668000, 5670000, 5790000, 5850000 ]
                                                  }, 'Bands'),
#6cm extends to 5925 MHz in Region 2 and 3

                  '3cm' => bless( { band => [10000000, 10500000],
                                                  }, 'Bands'),

#Bands above 10 GHz normally referred to by Frequency so make new entries by g and add aliases below for older ones

                  '12mm' => bless( { band => [24000000, 24250000],
                                                   }, 'Bands'),

                  '6mm' => bless( { band => [47000000, 47200000],
# Add beacon
														beacon => [ 47088000, 47090000 ]
                                                  }, 'Bands'),

                  '4mm' => bless( { band => [75500000, 81500000],
# Add beacon
														beacon => [ 75500000, 76000000, 77500000, 77501000 ]
                                                  }, 'Bands'),

                  '122g' => bless( { band => [122250000, 123000000],
                                                  }, 'Bands'),

                  '134g' => bless( { band => [134000000, 141000000],
# Add beacon
														beacon => [ 134000000, 134928000 ]
                                                  }, 'Bands'),

# Modify 248g to 241g

                  '241g' => bless( { band => [241000000, 250000000],
# Add beacon
														beacon => [ 248000000, 248001000 ]
                                                  }, 'Bands'),



                  'band1' => bless ( { band => [47000, 49999, 52000, 68000],
                                                         }, 'Bands'),

                  'band2' => bless ( { band => [87500, 108000],
                                                         }, 'Bands'),

                  'band3' => bless ( { band => [176000, 230000],
                                                         }, 'Bands'),

                  'band4' => bless ( { band => [471000, 550000],
                                                         }, 'Bands'),

                  'band5' => bless ( { band => [550000, 868000],
                                                         }, 'Bands'),

                  'military' => bless ( { band => [29700, 50000, 230000, 420000],
                                                                }, 'Bands'),

                  'aircraft' => bless ( { band => [108000, 137500],
                                                                }, 'Bands'),

                  'pmrlow' => bless ( { band => [68000, 87500],
                                                          }, 'Bands'),

                  'pmrmid' => bless ( { band => [138000, 165000],
                                                          }, 'Bands'),

                  'pmrhigh' => bless ( { band => [165000, 174000],
                                                           }, 'Bands'),

                  'pmruhf' => bless ( { band => [425000, 430000, 440000, 471000],
                                                          }, 'Bands'),
                   hf => bless ( { band => [1800, 29999], }, 'Bands'),
                   vhf => bless ( { band => [30000, 299999], }, 'Bands'),

# Bands according to IEEE standard:

                  'lband' => bless ( { band => [1000000, 2000000],
                                                          }, 'Bands'),

                  'sband' => bless ( { band => [2000000, 4000000],
                                                          }, 'Bands'),

	              'cband' => bless ( { band => [4000000, 8000000],
                                                          }, 'Bands'),

                  'xband' => bless ( { band => [8000000, 12000000],
                                                          }, 'Bands'),

                  'kuband' => bless ( { band => [12000000, 18000000],
                                                          }, 'Bands'),

                  'kband' => bless ( { band => [18000000, 27000000],
                                                          }, 'Bands'),

                  'kaband' => bless ( { band => [27000000, 40000000],
                                                          }, 'Bands'),

                  'vband' => bless ( { band => [40000000, 75000000],
                                                          }, 'Bands'),

                  'wband' => bless ( { band => [75000000, 110000000],
                                                          }, 'Bands'),

                  'gband' => bless ( { band => [110000000, 3000000000],
                                                          }, 'Bands'),
                 );

#
# fix up some aliases
#

$bands{'630m'} = $bands{'500khz'};
$bands{'24g'} = $bands{'12mm'};
$bands{'47g'} = $bands{'6mm'};
$bands{'76g'} = $bands{'4mm'};


#
# the list of regions
#
# this list is so that users can say 'vhf/ssb' instead of '6m/ssb, 4m/sbb, 2m/ssb'
# just shortcuts really
#
# DO make sure that the label exists in %bands!
#

%regions = (
                        vlf => [qw( 73khz 136khz 630m )],
                        hf => [qw( 160m 80m 60m 40m 30m 20m 17m 15m 12m 10m )],
                        contesthf => [qw( 160m 80m 40m 20m 15m 10m )],

# Add 8m and 5m Band
                        vhf => [qw( 8m 6m 5m 4m 2m 220 )],
                        vhfradio => [qw( band1 band2 )],
                        vhftv => [qw( band1 band3 )],

# Add 13cm Band
                        uhf => [qw( 70cm 902 23cm 13cm )],
                        uhftv => [qw( band4 band5 )],

# Modify. Error 23cm 13cm 47g 76g 121g 134g 248g not SHF
                        shf => [qw( 9cm 6cm 3cm 24g )],

# Add EHF
                        ehf => [qw( 47g 76g 121g 134g 241g )],
                        pmr => [qw( pmrlow pmrmid pmrhigh pmruhf )],
                        spe => [qw( 10m 8m 6m 5m 4m 2m )],
                        warc => [qw( 60m 30m 17m 12m )],

# DSN
						dsn => [qw( 23cm 9cm 6cm 3cm 24g 47g 76g 121g 134g 241g )],
                        all => [qw( 73khz 136khz 630m 160m 80m 60m 40m 30m 20m 17m 15m 12m 10m 8m 6m 5m 4m 2m 220 70cm 902 23cm 9cm 6cm 3cm 24g 47g 76g 121g 134g 241g )],
                   );
