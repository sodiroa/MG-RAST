package resources::inbox;

use strict;
use warnings;
no warnings('once');

use POSIX qw(strftime);
use HTTP::Request::StreamingUpload;
use HTTP::Headers;
use LWP::UserAgent;
use File::Basename;
use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex md5_base64);

use Conf;
use MGRAST::Metadata;
use parent qw(resources::resource);

# Override parent constructor
sub new {
    my ($class, @args) = @_;

    # Call the constructor of the parent class
    my $self = $class->SUPER::new(@args);
    
    # Add name / attributes
    $self->{name} = "inbox";
    $self->{base_attr} = {
        'id'        => ['string', "user id"],
        'user'      => ['string', "user login"],
        'status'    => ['string', "status message"],
        'timestamp' => ['string', "timestamp for return of this query"]
    };
    $self->{stat_attr} = {%{$self->{base_attr}}, ('stats_info' => ['hash', 'key value pairs describing file info'])};
    $self->{id_attr} = {%{$self->{base_attr}}, ('awe_id' => ['string', "url/id of awe job" ])};
    $self->{states} = ["completed", "deleted", "suspend", "in-progress", "pending", "queued"];
    # build workflow
    $self->{wf_info} = {
        shock_url     => $Conf::shock_url,
        job_name      => "",
        user_id       => 'mgu'.$self->user->_id,
        user_name     => $self->user->login,
        user_email    => $self->user->email,
        pipeline      => "inbox_action",
        clientgroups  => $Conf::mgrast_inbox_clientgroups,
        submission_id => undef,
        task_list     => ""
    };
    
    return $self;
}

# resource is called without any parameters
# this method must return a description of the resource
sub info {
    my ($self) = @_;
    my $content = {
        'name' => $self->name,
        'url' => $self->cgi->url."/".$self->name,
        'description' => "inbox receives user inbox data upload, requires authentication, see http://blog.metagenomics.anl.gov/mg-rast-v3-2-faq/#api_submission for details",
        'type' => 'object',
        'documentation' => $self->cgi->url.'/api.html#'.$self->name,
        'requests' => [
            { 'name'        => "info",
              'request'     => $self->cgi->url."/".$self->name,
              'description' => "Returns description of parameters and attributes.",
              'method'      => "GET",
              'type'        => "synchronous",  
              'attributes'  => "self",
              'parameters'  => {
                  'options'  => {},
                  'required' => {},
                  'body'     => {}
              }
            },
            { 'name'        => "view",
              'request'     => $self->cgi->url."/".$self->name,
              'description' => "lists the contents of the user inbox",
              'example'     => [ 'curl -X GET -H "auth: auth_key" "'.$self->cgi->url."/".$self->name.'"',
                  			     'lists the contents of the user inbox, auth is required' ],
              'method'      => "GET",
              'type'        => "synchronous",  
              'attributes'  => {
                  'id'        => [ 'string', "user id" ],
                  'user'      => [ 'string', "user login" ],
                  'timestamp' => [ 'string', "timestamp for return of this query" ],
                  'files'     => [ 'list', [ 'object', [
                                                { 'filename'  => [ 'string', "path of file from within user inbox" ],
                                                  'filesize'  => [ 'string', "disk size of file in bytes" ],
                                                  'checksum'  => [ 'string', "md5 checksum of file"],
                                                  'timestamp' => [ 'string', "timestamp of file" ]
                                                }, "list of file objects"] ] ],
                  'url'       => [ 'uri', "resource location of this object instance" ]
              },
              'parameters'  => {
                  'options'  => { "uuid" => [ "string", "RFC 4122 UUID for file" ] },
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                  'body'     => {}
              }
            },
            { 'name'        => "view_pending",
              'request'     => $self->cgi->url."/".$self->name."/pending",
              'description' => "view status of AWE inbox actions",
              'example'     => [ 'curl -X GET -H "auth: auth_key" "'.$self->cgi->url."/".$self->name.'/pending?queued&completed"',
                                 "rename file 'sequences.fastq' in user inbox, auth is required" ],
              'method'      => "GET",
              'type'        => "synchronous",
              'attributes'  => $self->{base_attr},
              'parameters'  => {
                  'options'  => { map { $_, ["boolean", "If true show the given state"] } @{$self->{states}} },
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                  'body'     => {}
              }
            },
            { 'name'        => "upload",
              'request'     => $self->cgi->url."/".$self->name,
              'description' => "receives user inbox data upload",
              'example'     => [ 'curl -X POST -H "auth: auth_key" -F "upload=@sequences.fastq" "'.$self->cgi->url."/".$self->name.'"',
                    			 "upload file 'sequences.fastq' to user inbox, auth is required" ],
              'method'      => "POST",
              'type'        => "synchronous",
              'attributes'  => $self->{base_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                  'body'     => { "upload" => ["file", "file to upload to inbox"] }
              }
            },
            { 'name'        => "delete",
              'request'     => $self->cgi->url."/".$self->name."/{UUID}",
              'description' => "delete indicated file from inbox",
              'example'     => [ 'curl -X DELETE -H "auth: auth_key" "'.$self->cgi->url."/".$self->name.'/cfb3d9e1-c9ba-4260-95bf-e410c57b1e49"',
                                 "delete file 'sequences.fastq' from user inbox, auth is required" ],
              'method'      => "DELETE",
              'type'        => "synchronous",
              'attributes'  => $self->{base_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ],
                                  "uuid" => [ "string", "RFC 4122 UUID for file" ] },
                  'body'     => {}
              }
            },
            { 'name'        => "file_info",
              'request'     => $self->cgi->url."/".$self->name."/info/{UUID}",
              'description' => "get basic file info - returns results and updates shock node",
              'example'     => [ 'curl -X GET -H "auth: auth_key" "'.$self->cgi->url."/".$self->name.'/info/cfb3d9e1-c9ba-4260-95bf-e410c57b1e49"',
                                 "get basic info for file with given id in user inbox, auth is required" ],
              'method'      => "GET",
              'type'        => "synchronous",
              'attributes'  => $self->{stat_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ],
                                  "uuid" => [ "string", "RFC 4122 UUID for file" ] },
                  'body'     => {}
              }
            },
            { 'name'        => "validate_metadata",
              'request'     => $self->cgi->url."/".$self->name."/validate/{UUID}",
              'description' => "validate metadata spreadsheet in inbox",
              'example'     => [ 'curl -X GET -H "auth: auth_key" "'.$self->cgi->url."/".$self->name.'/validate/cfb3d9e1-c9ba-4260-95bf-e410c57b1e49"',
                                 "validate metadata file with given id in user inbox, auth is required" ],
              'method'      => "GET",
              'type'        => "synchronous",
              'attributes'  => $self->{base_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ],
                                  "uuid" => [ "string", "RFC 4122 UUID for file" ] },
                  'body'     => {}
              }
            },
            { 'name'        => "seq_stats",
              'request'     => $self->cgi->url."/".$self->name."/stats/{UUID}",
              'description' => "runs sequence stats on file in user inbox - submits AWE job",
              'example'     => [ 'curl -X GET -H "auth: auth_key" "'.$self->cgi->url."/".$self->name.'/stats/cfb3d9e1-c9ba-4260-95bf-e410c57b1e49"',
                                 "runs seq stats on file with given id in user inbox, auth is required" ],
              'method'      => "GET",
              'type'        => "asynchronous",
              'attributes'  => $self->{id_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ],
                                  "uuid" => [ "string", "RFC 4122 UUID for sequence file" ] },
                  'body'     => {}
              }
            },
            { 'name'        => "rename",
              'request'     => $self->cgi->url."/".$self->name."/rename",
              'description' => "rename indicated file from inbox",
              'example'     => [ 'curl -X POST -H "auth: auth_key" "'.$self->cgi->url."/".$self->name.'/rename"',
                                 "rename file in user inbox, auth is required" ],
              'method'      => "POST",
              'type'        => "synchronous",
              'attributes'  => $self->{base_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ],
                                  "uuid" => [ "string", "RFC 4122 UUID for file" ] },
                  'body'     => { "name" => [ "string", "new name for file" ],
                                  "file" => [ "string", "RFC 4122 UUID for file" ] }
              }
            },
            { 'name'        => "sff_to_fastq",
              'request'     => $self->cgi->url."/".$self->name."/sff2fastq",
              'description' => "create fastq file from sff file - submits AWE job",
              'example'     => [ 'curl -X POST -H "auth: auth_key" -F "sff_file=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" "'.$self->cgi->url."/".$self->name.'/sff2fastq"',
                                 "create fastq file from sff file with given id in user inbox, auth is required" ],
              'method'      => "POST",
              'type'        => "asynchronous",
              'attributes'  => $self->{id_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                  'body'     => { "sff_file" => [ "string", "RFC 4122 UUID for sff file" ] }
              }
            },
            { 'name'        => "demultiplex",
              'request'     => $self->cgi->url."/".$self->name."/demultiplex",
              'description' => "demultiplex seq file with barcode file - submits AWE job",
              'example'     => [ 'curl -X POST -H "auth: auth_key" -F "seq_file=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" -F "barcode_file=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" "'.$self->cgi->url."/".$self->name.'/demultiplex"',
                                 "demultiplex seq file with barcode file for given ids in user inbox, auth is required" ],
              'method'      => "POST",
              'type'        => "asynchronous",
              'attributes'  => $self->{id_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                  'body'     => { "seq_file"      => [ "string", "RFC 4122 UUID for sequence file" ],
                                  "barcode_file"  => [ "string", "RFC 4122 UUID for barcode file" ] }
              }
            },
            { 'name'        => "pair_join",
              'request'     => $self->cgi->url."/".$self->name."/pairjoin",
              'description' => "merge overlapping paired-end fastq files - submits AWE job",
              'example'     => [ 'curl -X POST -H "auth: auth_key" -F "retain=1" -F "pair_file_1=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" -F "pair_file_2=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" "'.$self->cgi->url."/".$self->name.'/pairjoin"',
                                 "merge overlapping paired-end fastq files for given ids, retain non-overlapping pairs" ],
              'method'      => "POST",
              'type'        => "asynchronous",
              'attributes'  => $self->{id_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                  'body'     => { "pair_file_1" => [ "string", "RFC 4122 UUID for pair 1 file" ],
                                  "pair_file_2" => [ "string", "RFC 4122 UUID for pair 2 file" ],
                                  "output"      => [ "string", "prefix for output file, default is a random uuid" ],
                                  "retain"      => [ "boolean", "If true retain non-overlapping sequences, default is false" ] }
              }
            },
            { 'name'        => "pair_join_demultiplex",
              'request'     => $self->cgi->url."/".$self->name."/pairjoin_demultiplex",
              'description' => "merge overlapping paired-end fastq files and demultiplex based on index file - submits AWE job",
              'example'     => [ 'curl -X POST -H "auth: auth_key" -F "pair_file_1=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" -F "pair_file_2=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" -F "index_file=cfb3d9e1-c9ba-4260-95bf-e410c57b1e49" "'.$self->cgi->url."/".$self->name.'/pairjoin_demultiplex"',
                                 "merge overlapping paired-end fastq files then demultiplex with index file, for given ids" ],
              'method'      => "POST",
              'type'        => "asynchronous",
              'attributes'  => $self->{id_attr},
              'parameters'  => {
                  'options'  => {},
                  'required' => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                  'body'     => { "pair_file_1"   => [ "string", "RFC 4122 UUID for pair 1 file" ],
                                  "pair_file_2"   => [ "string", "RFC 4122 UUID for pair 2 file" ],
                                  "index_file"    => [ "string", "RFC 4122 UUID for optional index (barcode) file" ],
                                  "barcode_count" => [ "int", "number of unique barcodes in index_file" ],
                                  "output"        => [ "string", "prefix for output file names, default is a random uuid" ],
                                  "retain"        => [ "boolean", "If true retain non-overlapping sequences, default is false" ] }
              }
            }
        ]
    };
    $self->return_data($content);
}

# Override parent request function
sub request {
    my ($self) = @_;
    
    # must have auth
    if ($self->user) {
        # upload or view
        if (scalar(@{$self->rest}) == 0) {
            if ($self->method eq 'GET') {
                $self->view_inbox();
            } elsif ($self->method eq 'POST') {
                $self->upload_file();
            }
        } elsif (($self->method eq 'GET') && (scalar(@{$self->rest}) == 1)) {
            # view pending actions
            if ($self->rest->[0] eq 'pending') {
                $self->view_inbox_actions();
            }
            # view one file
            else {
                $self->view_inbox($self->rest->[0]);
            }    
        # inbox actions that don't run through AWE
        } elsif (($self->method eq 'GET') && (scalar(@{$self->rest}) > 1)) {
            if ($self->rest->[0] eq 'info') {
                $self->file_info($self->rest->[1]);
            } elsif ($self->rest->[0] eq 'validate') {
                $self->validate_metadata($self->rest->[1]);
            } elsif ($self->rest->[0] eq 'stats') {
                $self->seq_stats($self->rest->[1]);
            }
        # inbox actions that run through AWE
        } elsif (($self->method eq 'POST') && (scalar(@{$self->rest}) > 0)) {
            if ($self->rest->[0] eq 'rename') {
                $self->rename_file();
            } elsif ($self->rest->[0] eq 'sff2fastq') {
                $self->sff_to_fastq();
            } elsif ($self->rest->[0] eq 'demultiplex') {
                $self->demultiplex();
            } elsif ($self->rest->[0] eq 'pairjoin') {
                $self->pair_join();
            } elsif ($self->rest->[0] eq 'pairjoin_demultiplex') {
                $self->pair_join(1);
            }
        # deleting from inbox
        } elsif (($self->method eq 'DELETE') && (scalar(@{$self->rest}) == 1)) {
            $self->delete_file($self->rest->[0]);
        }
    }
    $self->info();
}

sub file_info {
    my ($self, $uuid) = @_;
    my ($node, $err_msg) = $self->get_file_info($uuid, undef, $self->token, $self->user_auth);
    $self->return_data({
        id         => 'mgu'.$self->user->_id,
        user       => $self->user->login,
        status     => $err_msg ? $err_msg : $node->{file}{name}." ($uuid) uploaded / updated",
        stats_info => $node->{attributes}{stats_info},
        timestamp  => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    });
}

sub validate_metadata {
    my ($self, $uuid) = @_;
    
    my $user_id = 'mgu'.$self->user->_id;
    my $response = {
        id        => $user_id,
        user      => $self->user->login,
        status    => "",
        timestamp => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    };
    # $uuid, $is_inbox, $extract_barcodes, $auth, $authPrefix, $submit_id
    my ($is_valid, $data, $log, $bar_id, $bar_count, $json_node) = $self->metadata_validation($uuid, 1, 1, $self->token, $self->user_auth);
    if ($is_valid) {
        $response->{status} = "valid metadata";
        if ($bar_id && $bar_count) {
            $response->{barcode_file} = $bar_id;
            $response->{barcode_count} = $bar_count;
        }
    } else {
        $response->{status} = "invalid metadata";
        $response->{error} = ($data && (@$data > 0)) ? $data : $log;
    }
    $self->return_data($response);
}

sub seq_stats {
    my ($self, $uuid) = @_;
    
    my $response = {
        id        => $self->{wf_info}{user_id},
        user      => $self->{wf_info}{user_name},
        status    => "$uuid: sequence stats computation",
        timestamp => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    };
    
    my $node = $self->node_from_inbox_id($uuid, $self->token, $self->user_auth);
    if (exists($node->{attributes}{data_type}) && ($node->{attributes}{data_type} eq "sequence")) {
        $response->{status} .= " has already been ran";
        $self->return_data($response);
    }
    
    my @tasks = $self->build_seq_stat_task(0, -1, $uuid, undef, $self->token, $self->user_auth);
    $self->{wf_info}{job_name}  = $self->{wf_info}{user_id}."_seqstats";
    $self->{wf_info}{task_list} = $self->json->encode(\@tasks);
    
    my $job = $self->submit_awe_template($self->{wf_info}, $Conf::mgrast_submission_workflow, $self->token, $self->user_auth);
    $self->add_node_action(undef, $node, $job, 'stats');
    
    # return data
    $response->{awe_id} = $Conf::awe_url.'/job/'.$job->{id};
    $response->{status} .= " is being run";
    $self->return_data($response);
}

# POST / AWE
sub sff_to_fastq {
    my ($self) = @_;

    # get and validate sequence file
    my $post = $self->get_post_data(['sff_file']);
    my $uuid = exists($post->{'sff_file'}) ? $post->{'sff_file'} : "";
    unless ($uuid) {
        $self->return_data( {"ERROR" => "this request type requires the sff_file parameter"}, 400 );
    }
    
    my @tasks = $self->build_sff_fastq_task(0, -1, $uuid, $self->token, $self->user_auth);
    $self->{wf_info}{job_name}  = $self->{wf_info}{user_id}."_sff2fastq";
    $self->{wf_info}{task_list} = $self->json->encode(\@tasks);
    
    my $job = $self->submit_awe_template($self->{wf_info}, $Conf::mgrast_submission_workflow, $self->token, $self->user_auth);
    $self->add_node_action($uuid, undef, $job, 'sff2fastq');
    
    # return data
    $self->return_data({
        id        => $self->{wf_info}{user_id},
        user      => $self->{wf_info}{user_name},
        status    => "$uuid: sff to fastq is being run",
        awe_id    => $Conf::awe_url.'/job/'.$job->{id},
        timestamp => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    });
}

# POST / AWE
sub demultiplex {
    my ($self) = @_;
    
    # get and validate files
    my $post = $self->get_post_data(['seq_file', 'barcode_file']);
    my $seq_file = exists($post->{'seq_file'}) ? $post->{'seq_file'} : "";
    my $bar_file = exists($post->{'barcode_file'}) ? $post->{'barcode_file'} : "";
    unless ($seq_file && $bar_file) {
        $self->return_data( {"ERROR" => "this request type requires both the seq_file and barcode_file parameters"}, 400 );
    }
    
    my @tasks = $self->build_demultiplex_task(0, -1, -1, $seq_file, $bar_file, 0, $self->token, $self->user_auth);
    my $seq_name = (keys %{$tasks[0]{inputs}})[0];
    $self->{wf_info}{job_name}  = $self->{wf_info}{user_id}."_demultiplex";
    $self->{wf_info}{task_list} = $self->json->encode(\@tasks);
    
    my $job = $self->submit_awe_template($self->{wf_info}, $Conf::mgrast_submission_workflow, $self->token, $self->user_auth);
    $self->add_node_action($seq_file, undef, $job, 'demultiplex');
    $self->add_node_action($bar_file, undef, $job, 'demultiplex');
    
    $self->return_data({
        id        => $self->{wf_info}{user_id},
        user      => $self->{wf_info}{user_name},
        status    => "$seq_file: demultiplex is being run",
        awe_id    => $Conf::awe_url.'/job/'.$job->{id},
        timestamp => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    });
}

# POST / AWE
sub pair_join {
    my ($self, $demultiplex) = @_;
    
    # get and validate sequence files
    my $post = $self->get_post_data(['pair_file_1', 'pair_file_2', 'index_file', 'output', 'barcode_count', 'retain']);
    my $pair1_file = exists($post->{'pair_file_1'}) ? $post->{'pair_file_1'} : "";
    my $pair2_file = exists($post->{'pair_file_2'}) ? $post->{'pair_file_2'} : "";
    my $index_file = exists($post->{'index_file'}) ? $post->{'index_file'} : "";
    my $outprefix  = exists($post->{'output'}) ? $post->{'output'} : $self->uuidv4();
    my $bc_count   = exists($post->{'barcode_count'}) ? $post->{'barcode_count'} : 0;
    my $retain     = exists($post->{'retain'}) ? $post->{'retain'} : 0;
    unless ($pair1_file && $pair2_file) {
        $self->return_data( {"ERROR" => "this request type requires both the pair_file_1 and pair_file_2 parameters"}, 400 );
    }
    my $status = "";
    my $action = "";
    
    # clean outprefix
    $outprefix =~ s/\.fastq$//;
    $outprefix =~ s/\.fq$//;
    
    # get tasks
    my @tasks = $self->build_pair_join_task(0, -1, -1, -1, $pair1_file, $pair2_file, $index_file, $bc_count, $outprefix, $retain, $self->token, $self->user_auth);
    
    # do pair-join with demultiplex
    if ($demultiplex) {
        unless ($index_file) {
            $self->return_data( {"ERROR" => "mate-pair demultiplexing requires the index_file parameter"}, 400 );
        }
        unless ($bc_count && ($bc_count > 1)) {
            $self->return_data( {"ERROR" => "barcode_count is required for mate-pair demultiplexing, must be greater than 1"}, 400 );
        }
        my $bc_tid = scalar(@tasks);
        push @tasks, $self->build_index_bc_task($bc_tid, -1, $index_file, $outprefix, $self->token, $self->user_auth);
        my $dm_tid = scalar(@tasks);
        push @tasks, $self->build_demultiplex_task($dm_tid, $bc_tid-1, $dm_tid-1, $outprefix.".fastq", $outprefix.".barcodes", $bc_count, $self->token, $self->user_auth);
        $status = "pair join and demultiplex is being run on files: $pair1_file, $pair2_file, $index_file";
        $action = "pairjoin_demultiplex";
    } else {
        $status = "pair join is being run on files: $pair1_file, $pair2_file";
        $action = "pairjoin";
    }
    
    $self->{wf_info}{job_name}  = $self->{wf_info}{user_id}."_".$action;
    $self->{wf_info}{task_list} = $self->json->encode(\@tasks);
    my $job = $self->submit_awe_template($self->{wf_info}, $Conf::mgrast_submission_workflow, $self->token, $self->user_auth);
    
    $self->add_node_action($pair1_file, undef, $job, $action);
    $self->add_node_action($pair2_file, undef, $job, $action);
    if ($demultiplex) {
        $self->add_node_action($index_file, undef, $job, $action);
    }
    
    $self->return_data({
        id        => $self->{wf_info}{user_id},
        user      => $self->{wf_info}{user_name},
        status    => $status,
        awe_id    => $Conf::awe_url.'/job/'.$job->{id},
        timestamp => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    });
}

sub view_inbox {
    my ($self, $uuid) = @_;

    my $user_id = 'mgu'.$self->user->_id;
    # get inbox
    my $inbox = [];
    if ($uuid) {
        $inbox = [ $self->node_from_inbox_id($uuid, $self->token, $self->user_auth) ];
    } else {
        $inbox = $self->get_shock_query({'type' => 'inbox', 'id' => $user_id}, $self->token, $self->user_auth);
    }
    # process inbox
    my $files = [];
    foreach my $node (@$inbox) {
        my $info = $self->node_to_inbox($node, $self->token, $self->user_auth);
        # check if any pending actions
        $self->update_node_actions($node);
        $info->{actions} = $node->{attributes}{actions};
        push @$files, $info;
    }
    $self->return_data({
        id        => $user_id,
        user      => $self->user->login,
        timestamp => strftime("%Y-%m-%dT%H:%M:%S", gmtime),
        files     => $files,
        url       => $self->cgi->url."/".$self->name
    });
}

sub view_inbox_actions {
    my ($self) = @_;

    my $jobs = [];
    my $user_id = 'mgu'.$self->user->_id;
    my $params = {
        "info.user" => [$user_id],
        "info.clientgroups" => ["mgrast_inbox"]
    };
    my $requestedStates = [];
    foreach my $state (@{$self->{states}}) {
        if ($self->cgi->param($state)) {
            push(@$requestedStates, $state);
        }
    }
    if (scalar(@$requestedStates)) {
        $params->{state} = $requestedStates;
    }
    $self->return_data($self->get_awe_query($params, $self->token, "mgrast"));
}

sub upload_file {
    my ($self) = @_;

    my $fn = $self->cgi->param('upload');
    if ($fn) {
        if ($fn !~ /^[\w\d_\.-]+$/) {
            $self->return_data({"ERROR" => "Invalid parameters, filename allows only word, underscore, dash (-), dot (.), and number characters"}, 400);
        }
        my $fh = $self->cgi->upload('upload');
        if (defined $fh) {
            # POST upload content to shock using file handle
            # data POST, not form
            my $response = undef;
            my $io_handle = $fh->handle;
            eval {
                my $post = HTTP::Request::StreamingUpload->new(
                    POST    => $Conf::shock_url.'/node',
                    fh      => $io_handle,
                    headers => HTTP::Headers->new(
                        'Content_Type' => 'application/octet-stream',
                        'Authorization' => $self->user_auth.' '.$self->token
                    )
                );
                my $req = LWP::UserAgent->new->request($post);
                $response = $self->json->decode( $req->content );
            };
            if ($@ || (! ref($response))) {
                $self->return_data({"ERROR" => "Unable to connect to Shock server"}, 507);
            } elsif (exists($response->{error}) && $response->{error}) {
                $self->return_data({"ERROR" => "Unable to POST to Shock: ".$response->{error}[0]}, $response->{status});
            }
            # PUT file name to node
            my $node_id = $response->{data}{id};
            my $node = $self->update_shock_node_file_name($node_id, "".$fn, $self->token, $self->user_auth);
            unless ($node && ($node->{id} eq $node_id)) {
                $self->return_data({"ERROR" => "storing object failed - unable to set file name"}, 507);
            }
            my $attr = {
                type  => 'inbox',
                id    => 'mgu'.$self->user->_id,
                user  => $self->user->login,
                email => $self->user->email
            };
            # PUT attributes to node
            $node = $self->update_shock_node($node_id, $attr, $self->token, $self->user_auth);
            # get / return file info
            $self->file_info($node_id);
        } else {
            $self->return_data( {"ERROR" => "storing object failed - could not obtain filehandle"}, 507 );
        }
    } else {
        $self->return_data( {"ERROR" => "invalid parameters, requires filename and data"}, 400 );
    }
}

sub delete_file {
    my ($self, $uuid) = @_;
    # check that no actions are being performed
    my $node = $self->node_from_inbox_id($uuid, $self->token, $self->user_auth);
    if (exists $node->{attributes}{actions}) {
        foreach my $act (@{$node->{attributes}{actions}}) {
            if (($act->{status} eq 'queued') || ($act->{status} eq 'in-progress')) {
                $self->return_data( {"ERROR" => "unable to delete file, ".$act->{name}." is ".$act->{status}}, 500 );
            }
        }
    }
    $self->delete_shock_node($uuid, $self->token, $self->user_auth);
    $self->return_data({
        id         => 'mgu'.$self->user->_id,
        user       => $self->user->login,
        status     => $node->{file}{name}." ($uuid) deleted",
        timestamp  => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    });
}

# POST
sub rename_file {
    my ($self) = @_;
    
    my $post = $self->get_post_data(['file', 'name']);
    my $uuid = exists($post->{'file'}) ? $post->{'file'} : "";
    my $name = exists($post->{'name'}) ? $post->{'name'} : "";
    unless ($uuid) {
        $self->return_data( {"ERROR" => "this request type requires the 'file' parameter"}, 400 );
    }
    unless ($name) {
        $self->return_data( {"ERROR" => "this request type requires the 'name' parameter"}, 400 );
    }
    my $node = $self->node_from_inbox_id($uuid, $self->token, $self->user_auth);
    my $attr = $node->{attributes};
    $self->update_shock_node_file_name($uuid, $name, $self->token, $self->user_auth);
    if (exists($attr->{stats_info}) && exists($attr->{stats_info}{file_name})) {
        $attr->{stats_info}{file_name} = $name;
        $node = $self->update_shock_node($uuid, $attr, $self->token, $self->user_auth);
    }
    $self->return_data({
        id         => 'mgu'.$self->user->_id,
        user       => $self->user->login,
        status     => $name." ($uuid) renamed",
        timestamp  => strftime("%Y-%m-%dT%H:%M:%S", gmtime)
    });
}

sub add_node_action {
    my ($self, $uuid, $node, $job, $name) = @_;
    
    # get node
    if ($node && ref($node)) {
        $uuid = $node->{id};
    } elsif ($uuid) {
        $node = $self->node_from_inbox_id($uuid, $self->token, $self->user_auth);
    }
    
    my $attr = $node->{attributes};
    my $actions = [];
    
    if (exists $attr->{actions}) {
        $actions = $attr->{actions};
    }
    push @$actions, {
        id => $job->{id},
        name => $name,
        status => ($job->{state} eq 'init') ? 'queued' : $job->{state},
        start => $job->{info}{submittime}
    };
    
    $attr->{actions} = $actions;
    $self->update_shock_node($node->{id}, $attr, $self->token, $self->user_auth);
}

sub update_node_actions {
    my ($self, $node) = @_;
    
    # get actions
    my $attr = $node->{attributes};
    my $new_actions = [];
    my $old_actions = [];
    if (exists $attr->{actions}) {
        $old_actions = $attr->{actions};
    }
    # check and update
    foreach my $act (@$old_actions) {
        # do nothing with completed
        if ($act->{status} eq 'completed') {
            push @$new_actions, $act;
        } else {
            my $job = $self->get_awe_job($act->{id}, $self->token, $self->user_auth);
            # drop it if deleted
            if ($job->{state} ne 'deleted') {
                $act->{status} = ($job->{state} eq 'init') ? 'queued' : $job->{state};
                push @$new_actions, $act;
            }
        }
    }
    # update node
    $attr->{actions} = $new_actions;
    $self->update_shock_node($node->{id}, $attr, $self->token, $self->user_auth);
}

1;
