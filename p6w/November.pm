use v6;

use CGI;
use Tags;
use HTML::Template;
use Text::Markup::Wiki::Minimal;
use November::Storage::File;  
use Session;
use Dispatcher;
use Utils;
use Config;

class November does Session {

    has $.template_path;
    has $.userfile_path;

    has November::Storage $.storage;
    has CGI     $.cgi;

    method init {
        # RAKUDO: set the attributes when declaring them
        $!template_path = Config.server_root ~ 'skin/';
        $!userfile_path = Config.server_root ~ 'data/users';

        $!storage = November::Storage::File.new();
        Session::init(self);
    }

    method handle_request(CGI $cgi) {
        $!cgi = $cgi;

        my $action = $cgi.params<action> // 'view';

        my $d = Dispatcher.new( default => { self.not_found } );

        $d.add_rules(
            [
            [''],                { self.view_page },
            ['view', /^ \w+ $/], { self.view_page(~$^page) },
            ['edit', /^ \w+ $/], { self.edit_page(~$^page) },
            ['in'],              { self.log_in },
            ['out'],             { self.log_out },
            ['recent'],          { self.list_recent_changes },
            ['all'],             { self.list_all_pages },
            ]
        );

        my @chunks =  $cgi.uri.chunks.list;
        $d.dispatch(@chunks);
    }

    method view_page($page='Main_Page') {

        unless $.storage.wiki_page_exists($page) {
            self.not_found($page);
            return;
        }

        my $minimal = Text::Markup::Wiki::Minimal.new( 
                        link_maker => { self.make_link($^p, $^t) } 
                      );

        # TODO: we need plugin system (see topics in mail-list)
        my $t = Tags.new;

        self.response( 'view.tmpl', 
            { 
            'TITLE'    => $page,
            'CONTENT'  => $minimal.format($.storage.read_page: $page), 
            'PAGETAGS' => $t.page_tags($page), 
            'TAGS'     => $t.cloud_tags,
            'RECENTLY' => self.get_changes( page => $page, :limit(8) ),
            }
        );

    }

    method edit_page($page) {
        my $sessions = self.read_sessions();

        return self.not_authorized() unless self.logged_in();

        my $already_exists
                        = $.storage.wiki_page_exists($page);
        my $action      = $already_exists ?? 'Editing' !! 'Creating';
        my $old_content = $already_exists ?? $.storage.read_page($page) !! '';
        my $title = "$action $page";

        # The 'edit' action handles both showing the form and accepting the
        # POST data. The difference is the presence of the 'articletext'
        # parameter -- if there is one, the action is considered a save.
        if $.cgi.params<articletext> || $.cgi.params<tags> {
            my $new_text   = $.cgi.params<articletext>;
            my $tags       = $.cgi.params<tags>;
            my $session_id = $.cgi.cookie<session_id>;
            my $author     = $sessions{$session_id}<user_name>;
            $.storage.save_page($page, $new_text, $author);

            # TODO: we need plugin system (see topics in mail-list)
            my $t = Tags.new();
            $t.update_tags($page, $tags);

            $.cgi.redirect('/view/' ~ $page );
            return;
        }

        # TODO: we need plugin system (see topics in mail-list)
        my $t = Tags.new;

        self.response( 'edit.tmpl', 
            { 
            'PAGE'      => $page,
            'TITLE'     => $title,
            'CONTENT'   => $old_content,
            'PAGETAGS' => $t.read_page_tags($page),
            }
        );
    }

    method logged_in() {
        my $sessions = self.read_sessions();
        my $session_id = $.cgi.cookie<session_id>;
        # RAKUDO: 'defined' should maybe be 'exists', although here it doesn't
        # matter.
        defined $session_id && defined $sessions{$session_id}
    }

    method not_authorized {
        self.response( 'action_not_authorized.tmpl', 
            { 
            # TODO: file bug, without "'" it is interpreted as named 
            # args and not as Pair
            'DISALLOWED_ACTION' => 'edit pages'
            }
        );
    }

    method read_users {
        return {} unless $.userfile_path ~~ :e;
        return eval( slurp( $.userfile_path ) );
    }

    method not_found($page?) {
        #TODO: that should by 404 when no $page 
        self.response('not_found.tmpl', 
            { 
            'PAGE' => $page || 'Action Not found'
            }
        );
    }

    method log_in {
        if my $user_name = $.cgi.params<user_name> {

            my $password = $.cgi.params<password>;

            my %users = self.read_users();

            # Yes, this is cheating. Stand by for a real MD5 hasher.
            if (defined %users{$user_name} 
               and $password eq %users{$user_name}<plain_text>) {
#            if Digest::MD5::md5_base64(
#                   Digest::MD5::md5_base64($user_name) ~ $password
#               ) eq %users{$user_name}<password> {

                my $session_id = self.new_session($user_name);
                my $session_cookie = "session_id=$session_id";

                self.response('login_succeeded.tmpl', 
                    {},
                    { cookie => $session_cookie }
                );
            }

            self.response('login_failed.tmpl'); 
        }

        self.response('log_in.tmpl');
    }

    method log_out {
        if defined $.cgi.cookie<session_id> {
            my $session_id = $.cgi.cookie<session_id>;
            self.remove_session( $session_id );

            my $session_cookie = "session_id=";

            self.response('logout_succeeded.tmpl',
                undef,
                { :cookie($session_cookie) }
            );
        }

        self.response('logout_succeeded.tmpl');
    }


    method list_recent_changes {
        my @changes = self.get_changes(limit => 50);
        self.response('recent_changes.tmpl',
            {
            'CHANGES'   => @changes,
            'LOGGED_IN' => self.logged_in
            }
        );
    }

    method get_changes (:$page, :$limit) {

        # RAKUDO: Seemingly impossible to get the right number of list
        # containers using an array variable @recent_changes here.
        my $recent_changes;

        if $page {
            $recent_changes = $.storage.read_page_history($page);
        }
        else {
            $recent_changes = $.storage.read_recent_changes;
        }

        # @recent_changes = @recent_changes[0..$limit] if $limit;
        # RAKUDO: array slices do not implemented yet, so:
        my @changes;
        for $recent_changes.list -> $modification_id {
            my $modification = $.storage.read_modification($modification_id);
            my $count = push @changes, {
                'page' => self.make_link($modification[0]),
                'time' => time_to_period_str($modification[3]) || $modification_id,
                'author' => $modification[2] || 'somebody' 
                };
            # RAKUDO: last not implemented yet :(
            return @changes if $limit && $count == $limit;
        }
        return @changes;
    }

    method list_all_pages {

        my $t = Tags.new();
        my %params;
        %params<TAGS> = $t.cloud_tags if $t;

        my $index;

        my $tag = $.cgi.params<tag>;
        if $tag and $t {
            # TODO: we need plugin system (see topics in mail-list)
            my $tags_index = $t.read_tags_index;
            $index = $tags_index{$tag};
            %params<TAGS> = $tag;
        } 
        else {
            $index = $.storage.read_index;
        }

        if $index {
            # HTML::Template eat only Arrey of Hashes and Hash keys should 
            # be in low case. HTML::Template in new-html-template brunch 
            # will be much clever.

            # RAKUDO: @($arrayref) not implemented yet, so:
            # my @list = map { { page => $_ } }, @($index); 
            # do not work. Workaround:
            my @list = map { { page => $_ } }, $index.list; 
            %params<LIST> = @list;
        }

        self.response('list_all_pages.tmpl', %params);
    }

    method response ($tmpl, %params?, %opts?) {
        my $template = HTML::Template.new(
            filename => $.template_path ~ $tmpl);

        $template.params =
            'WEBROOT' => Config.web_root,
            'LOGGED_IN' => self.logged_in,
            %params.kv;

        $.cgi.send_response($template.output, %opts);
    }

    method make_link($page, $title?) {
        my $root = Config.server_root;
        if $title {
            if $page ~~ m/':'/ {
                return qq|<a href="{ $root ~ $page }">$title</a>|;
            } else {
                return qq|<a href="$root/view/$page">$title</a>|;
            }
        } else {
            # TODO: do that more readable
            return sprintf('<a href="%s/%s/%s" %s >%s</a>',
                           $root,
                           $.storage.wiki_page_exists($page)
                             ?? ('view', $page, '')
                             !! ('edit', $page, ' class="nonexistent"'),
                           $page);
        }
    }

}

# vim:ft=perl6
