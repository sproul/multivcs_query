require_relative 'u'
require 'rubygems'
require 'xmlsimple'
require 'fileutils'
require 'pp'
require 'net/http'
require 'json'

STDOUT.sync = true      # otherwise some output can get lost if there is an exception or early exit

class Error_record < Exception
        attr_accessor :emsg
        attr_accessor :http_response_code
        def initialize(emsg, http_response_code=nil)
                self.emsg = emsg # If we want to encapsulate stack trace in emsg, add this:              + "\n" + self.current_backtrace
                self.http_response_code = http_response_code
        end
        def current_backtrace()
                # get stack, but don't include Error_record frames
                z = ""
                skipping_initial_error_record_frames = true
                Thread.current.backtrace.each do | frame |
                        if skipping_initial_error_record_frames
                                if frame =~ /:in `raise'$/
                                        skipping_initial_error_record_frames = false
                                end
                        else
                                z << frame << "\n"
                        end
                end
                z
        end
        def to_s()
                z = "Error_record("
                if self.http_response_code
                        z << "http_response_code=#{self.http_response_code}, "
                else
                        z << ""
                end
                z << "emsg=#{self.emsg})"
        end
        class << self
                attr_accessor :emsg
                attr_accessor :http_response_code
        end
end

class Error_holder
        attr_accessor :error
        def exception()
                self.error
        end
        def raise(emsg, http_response_code=nil)
                self.error = Error_record.new(emsg, http_response_code)
                Kernel.raise self
        end
        class << self
                def raise(emsg, http_response_code=nil)
                        eh = Error_holder.new
                        eh.raise(emsg, http_response_code)
                end
        end
end

class Change_tracker
        HOST_NAME_DEFAULT = "localhost"
        PORT_DEFAULT = 11111

        attr_accessor :host_name
        attr_accessor :port
        def initialize(host_name = Change_tracker::HOST_NAME_DEFAULT, port = Change_tracker::PORT_DEFAULT)
                self.host_name = host_name
                self.port = port.to_s
        end
        def to_s()
                "Change_tracker(#{self.host_name}:#{self.port})"
        end
        def eql?(other)
                self.host_name.eql?(other.host_name) && self.port.eql?(other.port)
        end
        class << self
        end
end

class File_set
        attr_accessor :repo
        attr_accessor :file_list
        def initialize(repo, file_list)
                self.repo = repo
                self.file_list = file_list.sort
        end
        def to_json()
                h = Hash.new
                h[self.repo.spec] = file_list
                h.to_json
        end
end

class File_sets
        attr_accessor :file_sets
        def initialize()
                self.file_sets = Hash.new
        end
        def add_set(file_set)
                fsrs = file_set.repo.spec
                if self.file_sets.has_key?(fsrs)
                        self.file_sets[fsrs] = (self.file_sets[fsrs] + file_set.file_list).uniq.sort
                else
                        self.file_sets[fsrs] = file_set.file_list
                end
        end
        def add_sets(other_fs)
                other_fs.file_sets.each do | set |
                        self.add_set(set)
                end
        end
        def eql?(other)
                if self.file_sets.size != other.file_sets.size
                        return false
                end
                self.file_sets.keys.each do | repo |
                        if !self.file_sets[repo].eql?(other.file_sets[repo])
                                return false
                        end
                end
                return true
        end
        def to_json()
                self.file_sets.to_json
        end
        class << self
                TEST_REPO_NAME1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;"
                TEST_REPO_NAME2 = "git;git.osn.oraclecorp.com;osn/cec-else;"

                def test()
                        r1 = Git_repo.new(TEST_REPO_NAME1)
                        r2 = Git_repo.new(TEST_REPO_NAME2)
                        fs1 = File_set.new(r1, ["a", "b"])
                        fs2 = File_set.new(r1, ["a", "b"])
                        fs3 = File_set.new(r2, ["a", "z"])
                        fss1 = File_sets.new
                        fss1.add_set(fs1)
                        fss2 = File_sets.new
                        fss2.add_set(fs1)
                        U.assert_eq(fss1, fss2, "File_sets.test0")
                        fss2.add_set(fs2)
                        U.assert_eq(fss1, fss2, "File_sets.test1")
                        fss2.add_set(File_set.new(r1, ["c", "b"]))
                        U.assert_json_eq({r1.spec => ["a", "b", "c"]}, fss2, "File_sets.test2")
                        fss2.add_set(fs3)
                        U.assert_json_eq({r1.spec => ["a", "b", "c"], r2.spec => ["a", "z"]}, fss2, "File_sets.test3")
                end
        end
end


class Json_obj
        attr_accessor :h
        def initialize(json_text = nil)
                if json_text
                        self.h = JSON.parse(json_text)
                else
                        self.h = Hash.new
                end
        end
        def array_of_json_to_s(a, multi_line_mode = false)
                z = nil
                a.each do | elt |
                        if !z
                                z = "["
                        else
                                z << ","
                        end
                        z << "\n" if multi_line_mode
                        z << elt.json
                end
                z << "\n" if multi_line_mode
                z << "]"
                z
        end
        def to_s()
                "Json_obj(#{self.h})"
        end
        def get(key, default_val = nil)
                if !self.h.has_key?(key)
                        if default_val
                                return default_val
                        else
                                raise "no match for key #{key} in #{self.h}"
                        end
                end
                h[key]
        end
        def has_key?(key)
                h.has_key?(key)
        end
end

class Git_repo < Error_holder
        DEFAULT_BRANCH = "master"

        attr_accessor :project_name
        attr_accessor :global_data_prefix
        attr_accessor :branch_name
        attr_accessor :source_control_server
        attr_accessor :source_control_type
        attr_accessor :change_tracker_host_and_port

        def initialize(repo_spec, change_tracker_host_and_port = nil)
                self.change_tracker_host_and_port = change_tracker_host_and_port
                # type         ;  host   ; proj     ;brnch
                if repo_spec !~ /^(\w+);([-\w\.]+);([-\.\w\/]+);(\w*)$/
                        self.raise("cannot understand repo spec #{repo_spec}", 500)
                end
                # git;git.osn.oraclecorp.com;osn/cec-server-integration;master
                # type;  host               ; proj                     ;branch
                self.source_control_type, self.source_control_server, self.project_name, self.branch_name = $1,$2,$3,$4
                if source_control_type != "git"
                        self.raise("unexpected source_control_type #{source_control_type} from #{repo_spec}", 501)
                end
                self.source_control_type = source_control_type
                if !branch_name || branch_name == ""
                        self.branch_name = DEFAULT_BRANCH
                else
                        self.branch_name = branch_name
                end
                self.raise("empty project name") unless project_name && (project_name != "")
                self.project_name = project_name
                self.global_data_prefix = "git_repo_#{project_name}."
                self.source_control_server = source_control_server
                if !Git_repo.codeline_root_parent
                        Git_repo.codeline_root_parent = Global.get_scratch_dir("git")
                end
        end
        def latest_commit_id()
                self.system("git log --pretty=format:'%H' -n 1")
        end
        def spec()
                Git_repo.make_spec(source_control_server, project_name, branch_name, change_tracker_host_and_port)
        end
        def to_s()
                spec
        end
        def eql?(other)
                self.project_name.eql?(other.project_name) &&
                self.change_tracker_host_and_port.eql?(other.change_tracker_host_and_port) &&
                self.branch_name.eql?(other.branch_name)
        end
        def get(key, default_val=nil)
                Global.get(self.global_data_prefix + key, default_val)
        end
        def get_project_name_prefix()
                project_name.sub(/\/.*/, '')
        end
        def get_file(path, commit_id)
                fn = "#{self.codeline_disk_root}/#{path}"
                # for current synced file, you can execute the following, but really I need to be able to pull out content by commit_id:
                #if !File.exist?(fn)
                #self.raise "could not read #{fn}"
                #end
                #IO.read(fn)

                saved_file_by_commit = "#{fn}.___#{commit_id}"
                if !File.exist?(saved_file_by_commit)
                        cmd = "git show #{commit_id}:#{path} > #{saved_file_by_commit}"
                        self.system(cmd)
                end
                IO.read(saved_file_by_commit)
        end
        def get_credentials()
                username, pw = Global.get_credentials("#{source_control_server}/#{project_name}", true)
                if !username
                        username, pw = Global.get_credentials(source_control_server, true)
                end
                return username, pw
        end
        def codeline_disk_exist?()
                root_dir = codeline_disk_root()
                # puts "exist? checking #{root_dir}"
                # if dir is empty, then there are 2 entries (., ..):
                return Dir.exist?(root_dir) && (Dir.entries(root_dir).size > 2)
        end
        def codeline_disk_root()
                "#{Git_repo.codeline_root_parent}/#{self.source_control_server}/#{project_name}"
        end
        def codeline_disk_remove()
                root_dir = codeline_disk_root()
                FileUtils.rm_rf(root_dir)
        end
        def codeline_disk_write(commit_id = nil)
                root_dir = codeline_disk_root()
                if !codeline_disk_exist?
                        root_parent = File.dirname(root_dir)       # leave it to 'git clone' to make the root_dir itself
                        FileUtils.mkdir_p(root_parent)

                        username, pw = self.get_credentials
                        if !username
                                git_arg = "git@#{self.source_control_server}:#{project_name}.git"
                        else
                                username_pw = "#{username}"
                                if pw != ""
                                        username_pw << ":#{pw}"
                                end
                                git_arg = "https://#{username_pw}@#{self.source_control_server}/#{project_name}.git"
                        end
                        if branch_name && branch_name != DEFAULT_BRANCH
                                branch_arg = "-b \"#{branch_name}\""
                        else
                                branch_arg = ""
                        end
                        # from Steve mail -- not sure if I've accounted for everything already...
                        # git clone ...
                        # git checkout master
                        # git pull      # may not be necessary
                        #
                        U.system("git clone #{branch_arg} \"#{git_arg}\"", nil, root_parent)
                end
                if !codeline_disk_exist?
                        self.raise "error: #{self} does not exist on disk after supposed clone"
                end
                root_dir
        end
        def system_as_list(cmd)
                local_codeline_root_dir = self.codeline_disk_write
                self.raise "no codeline for #{self}" unless local_codeline_root_dir
                U.system_as_list(cmd, nil, local_codeline_root_dir)
        end
        def system(cmd)
                local_codeline_root_dir = self.codeline_disk_write
                self.raise "no codeline for #{self}" unless local_codeline_root_dir
                U.system(cmd, nil, local_codeline_root_dir)
        end
        class << self
                TEST_REPO_NAME = "git;git.osn.oraclecorp.com;osn/cec-server-integration;"
                attr_accessor :codeline_root_parent
                def make_spec(source_control_server, repo_name, branch=DEFAULT_BRANCH, change_tracker_host_and_port=nil)
                        source_control_type = "git"
                        self.raise "bad source_control_server #{source_control_server}" unless source_control_server && source_control_server.is_a?(String) && source_control_server != ""
                        self.raise "bad repo_name #{repo_name}" unless repo_name && repo_name.is_a?(String) && repo_name != ""
                        branch = "" unless branch
                        change_tracker_host_and_port = "" unless change_tracker_host_and_port
                        "#{source_control_type};#{source_control_server};#{repo_name};#{branch}"        #       ;#{change_tracker_host_and_port}"
                end
                def test_clean()
                        gr = Git_repo.new(TEST_REPO_NAME)
                        gr.codeline_disk_remove
                        U.assert(!gr.codeline_disk_exist?)
                end
                def test()
                        gr = Git_repo.new(TEST_REPO_NAME)
                        gr.codeline_disk_write
                        U.assert(gr.codeline_disk_exist?)
                        deps_gradle_content = gr.get_file("deps.gradle", "2bc0b1a58a9277e97037797efb93a2a94c9b6d99")
                        U.assert(deps_gradle_content)
                        U.assert(deps_gradle_content != "")
                        manifest_lines = deps_gradle_content.split("\n").grep(/manifest/)
                        U.assert(manifest_lines.size > 1)
                end
        end
end

class Git_cspec < Error_holder
        attr_accessor :repo
        attr_accessor :commit_id
        attr_accessor :comment  # only set if this object populated by a call to git log
        def initialize(repo_expr, commit_id, comment=nil)
                if repo_expr.is_a? String
                        repo_spec = repo_expr
                        self.repo = Git_repo.new(repo_spec)
                elsif repo_expr.is_a? Git_repo
                        self.repo = repo_expr
                else
                        self.raise "unexpected repo type #{repo.class}"
                end
                self.commit_id = commit_id
                self.comment = comment
        end
        def unreliable_autodiscovery_of_dependencies_from_build_configuration()
                self.repo.codeline_disk_write
                deps_gradle_content = self.repo.get_file("deps.gradle", self.commit_id)
                dependency_commits = Cec_gradle_parser.to_dep_commits(deps_gradle_content, self.repo)
                dependency_commits
        end
        def list_changes_since(other_commit)
                change_lines = repo.system_as_list("git log --pretty=format:'%H %s' #{other_commit.commit_id}..#{commit_id}")
                commits = []
                change_lines.map.each do | change_line |
                        self.raise "did not understand #{change_line}" unless change_line =~ /^([0-9a-f]+) (.*)$/
                        change_id, comment = $1, $2
                        commits << Git_cspec.from_repo_and_commit_id("#{repo.spec};#{change_id}", comment)
                end
                commits
        end
        def list_changed_files()
                File_set.new(self.repo, repo.system_as_list("git diff-tree --no-commit-id --name-only -r #{self.commit_id}"))
        end
        def list_files_changed_since(other_commit)
                commits = list_changes_since(other_commit)
                fss = File_sets.new
                commits.each do | commit |
                        fss.add_set(commit.list_changed_files)
                end
                return fss
        end
        def eql?(other)
                other && self.repo.eql?(other.repo) && self.commit_id.eql?(other.commit_id)
        end
        def to_s()
                z = "Git_cspec(#{self.repo.spec}, #{self.commit_id}"
                if self.comment
                        z << ", !!!#{comment}!!!"
                end
                z << ")"
                z
        end
        def to_s_with_comment()
                self.raise "comment not set" unless comment
                to_s
        end
        def to_json()
                h = Hash.new
                h["repo_spec"] = repo.to_s
                h["commit_id"] = commit_id
                if comment
                        h["comment"] = comment
                end
                JSON.pretty_generate(h)
        end
        def codeline_disk_write()
                repo.codeline_disk_write(self.commit_id)
        end
        def component_contained_by?(cspec_set)
                self.find_commit_for_same_component(cspec_set) != nil
        end
        def list_files_added_or_updated()
                # https://stackoverflow.com/questions/424071/how-to-list-all-the-files-in-a-commit
                repo.system_as_list("git diff-tree --no-commit-id --name-only -r #{self.commit_id}")
        end
        def list_files()
                # https://stackoverflow.com/questions/8533202/list-files-in-local-git-repo
                repo.system_as_list("git ls-tree --full-tree -r HEAD --name-only")
        end
        def list_bug_IDs_since(other_commit)
                changes = list_changes_since(other_commit)
                bug_IDs = Git_cspec.grep_group1(changes, Cspec_set.bug_id_regexp)
                bug_IDs
        end
        def find_commit_for_same_component(cspec_set)
                cspec_set.commits.each do | commit |
                        if commit.repo.eql?(self.repo)
                                return commit
                        end
                end
                return nil
        end
        def repo_and_commit_id()
                "#{self.repo.spec};#{self.commit_id}"
        end
        class << self
                TEST_SOURCE_SERVER_AND_PROJECT_NAME = "orahub.oraclecorp.com;faiza.bounetta/promotion-config"
                TEST_REPO_SPEC = "git;#{TEST_SOURCE_SERVER_AND_PROJECT_NAME};"

                def list_changes_between(commit_spec1, commit_spec2)
                        commit1 = Git_cspec.from_repo_and_commit_id(commit_spec1)
                        commit2 = Git_cspec.from_repo_and_commit_id(commit_spec2)
                        return commit2.list_changes_since(commit1)
                end
                def from_hash(h)
                        if h.has_key?("gitRepoName")
                                # puts "fh: #{h}"
                                # fh: Json_obj({"gitUItoCommit"=>"https://orahub.oraclecorp.com/faiza.bounetta/promotion-config/commit/dc68aa99903505da966358f96c95f946901c664b", "gitRepoName"=>"orahub.oraclecorp.com;faiza.bounetta/promotion-config", "gitBranch"=>"master", "gitCommitId"=>"dc68aa99903505da966358f96c95f946901c664b", "dependencies"=>[]})
                                change_tracker_host_and_port = h.get("change_tracker_host_and_port", "")
                                source_control_server_and_repo_name = h.get("gitRepoName")
                                branch         = h.get("gitBranch")
                                commit_id      = h.get("gitCommitId")
                                source_control_server, repo_name = source_control_server_and_repo_name.split(/;/)
                                repo_spec = Git_repo.make_spec(source_control_server, repo_name, branch, change_tracker_host_and_port)
                        else
                                repo_spec = h.get("repo_spec")
                                commit_id = h.get("commit_id")
                        end
                        Git_cspec.new(repo_spec, commit_id)
                end
                def from_s(s, arg_name="Git_cspec.from_s")
                        if s.start_with?('http')
                                url = s
                                return from_s(U.rest_get(url), "#{arg_name} => #{url}")
                        end
                        json_text = s
                        begin
                                json_obj = Json_obj.new(json_text)
                        rescue JSON::ParserError => jpe
                                Error_holder.raise("trouble parsing #{arg_name} \"#{s}\": #{jpe.to_s}", 400)
                        end
                        # puts "gc from_s: #{json_text}"
                        # gc fromjson: {"repo_spec" : "git;git.osn.oraclecorp.com;osn/cec-server-integration;master","commit_id" : "2bc0b1a58a9277e97037797efb93a2a94c9b6d99"}
                        repo_spec = json_obj.get("repo_spec")
                        commit_id = json_obj.get("commit_id")
                        Git_cspec.new(repo_spec, commit_id)
                end
                def from_repo_and_commit_id(repo_and_commit_id, comment=nil)
                        if repo_and_commit_id !~ /(.*);([^;]*)$/
                                raise "could not parse #{repo_and_commit_id}"
                        end
                        repo_spec, commit_id = $1, $2
                        gr = Git_repo.new(repo_spec)
                        if commit_id == ""
                                commit_id = gr.latest_commit_id
                        end
                        Git_cspec.new(gr, commit_id, comment)
                end
                def is_repo_and_commit_id?(s)
                        # git;git.osn.oraclecorp.com;osn/cec-server-integration;master;aaaaaaaaaaaa
                        # type         ;  host   ; proj     ;brnch;commit_id
                        if s =~ /^(\w+);([-\w\.]+);([-\w\.\/]+);(\w*);(\w+)$/
                                true
                        else
                                false
                        end
                end
                def grep_group1(commits, regexp)
                        raise "no regexp" unless regexp
                        group1_hits = []
                        commits.each do | commit |
                                raise "comment not set for #{commit}" unless commit.comment
                                if regexp.match(commit.comment)
                                        raise "no group 1 match for #{regexp}" unless $1
                                        group1_hits << $1
                                end
                        end
                        group1_hits
                end
                def list_files_changed_between(commit_spec1, commit_spec2)
                        commit1 = Git_cspec.from_repo_and_commit_id(commit_spec1)
                        commit2 = Git_cspec.from_repo_and_commit_id(commit_spec2)
                        return commit2.list_files_changed_since(commit1)
                end
                def test_list_changes_since()
                        compound_spec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;6b5ed0226109d443732540fee698d5d794618b64"
                        compound_spec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"
                        gc1 = Git_cspec.from_repo_and_commit_id(compound_spec1)
                        gc2 = Git_cspec.from_repo_and_commit_id(compound_spec2)
                        changes = gc2.list_changes_since(gc1)
                        changes2 = Git_cspec.list_changes_between(compound_spec1, compound_spec2)
                        U.assert_eq(changes, changes2, "Git_cspec.test_list_changes_since - vfy same result from wrapper 0")

                        g1b = Git_cspec.from_repo_and_commit_id("git;git.osn.oraclecorp.com;osn/cec-server-integration;master;22ab587dd9741430c408df1f40dbacd56c657c3f")
                        g1a = Git_cspec.from_repo_and_commit_id("git;git.osn.oraclecorp.com;osn/cec-server-integration;master;7dfff5f400b3011ae2c4aafac286d408bce11504")

                        U.assert_eq([gc2, g1b, g1a], changes)
                end
                def test_list_files_changed_since()
                        compound_spec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;6b5ed0226109d443732540fee698d5d794618b64"
                        compound_spec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"
                        gc1 = Git_cspec.from_repo_and_commit_id(compound_spec1)
                        gc2 = Git_cspec.from_repo_and_commit_id(compound_spec2)

                        changed_files = gc2.list_files_changed_since(gc1)
                        changed_files2 = Git_cspec.list_files_changed_between(compound_spec1, compound_spec2)
                        U.assert_eq(changed_files, changed_files2, "vfy same result from wrapper 1")
                        U.assert_json_eq({"git;git.osn.oraclecorp.com;osn/cec-server-integration;master" => ["component.properties", "deps.gradle"]}, changed_files, "Git_cspec.test_list_files_changed_since")
                end
                def test_json()
                        repo_spec = "git;git.osn.oraclecorp.com;osn/cec-server-integration;master"
                        valentine_commit_id = "2bc0b1a58a9277e97037797efb93a2a94c9b6d99"
                        gc = Git_cspec.new(repo_spec, valentine_commit_id)
                        json = gc.to_json
                        U.assert_json_eq('{"repo_spec":"git;git.osn.oraclecorp.com;osn/cec-server-integration;master","commit_id":"2bc0b1a58a9277e97037797efb93a2a94c9b6d99"}', json, 'Git_cspec.test_json')
                        gc2 = Git_cspec.from_s(json)
                        U.assert_eq(gc, gc2, "test ability to export to json, then import from that json back to the same object")
                end
                def test_list_bug_IDs_since()
                        # I noticed that for the commits in this range, there is a recurring automated comment "caas.build.pl.master/3013/" -- so
                        # I thought I would reset the pattern to treat that number like a bug ID for the purposes of the test.
                        # (At some point, i'll need to go find a comment that really does refer to a bug ID.)
                        saved_bug_id_regexp = Cspec_set.bug_id_regexp_val
                        begin
                                compound_spec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;6b5ed0226109d443732540fee698d5d794618b64"
                                compound_spec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"
                                gc1 = Git_cspec.from_repo_and_commit_id(compound_spec1)
                                gc2 = Git_cspec.from_repo_and_commit_id(compound_spec2)
                                Cspec_set.bug_id_regexp_val = Regexp.new(".*caas.build.pl.master/(\\d+)/.*", "m")
                                bug_IDs = gc2.list_bug_IDs_since(gc1)
                                U.assert_eq(["3013", "3012", "3011"], bug_IDs, "bug_IDs_since")

                                bug_IDs2 = Cspec_set.list_bug_IDs_between(compound_spec1, compound_spec2)
                                U.assert_eq(bug_IDs, bug_IDs2, "verify same result  from list_bug_IDs_between wrapper")
                        ensure
                                Cspec_set.bug_id_regexp_val = saved_bug_id_regexp
                        end
                end
                def test()
                        U.assert_eq(true, Git_cspec.is_repo_and_commit_id?("git;git.osn.oraclecorp.com;ccs/caas;master;a1466659536cf2225eadf56f43972a25e9ee1bed"), "Git_cspec.is_repo_and_commit_id")
                        U.assert_eq(true, Git_cspec.is_repo_and_commit_id?("git;git.osn.oraclecorp.com;osn/cec-server-integration;master;2bc0b1a58a9277e97037797efb93a2a94c9b6d99"), "Git_cspec.is_repo_and_commit_id 2")
                        
                        test_list_bug_IDs_since()
                        test_list_changes_since()

                        gc1 = Git_cspec.new(TEST_REPO_SPEC, "dc68aa99903505da966358f96c95f946901c664b")
                        gc2 = Git_cspec.new(TEST_REPO_SPEC, "42f2d95f008ea14ea3bb4487dba8e3e74ce992a1")
                        gc1_file_list = gc1.list_files
                        gc2_file_list = gc2.list_files
                        U.assert_eq(713, gc1_file_list.size)
                        U.assert_eq(713, gc2_file_list.size)
                        U.assert_eq(".gitignore", gc1_file_list[0])
                        U.assert_eq(".gitignore", gc2_file_list[0])
                        U.assert_eq("version.txt", gc1_file_list[712])
                        U.assert_eq("version.txt", gc2_file_list[712])
                        gc1_added_or_changed_file_list = gc1.list_files_added_or_updated
                        gc2_added_or_changed_file_list = gc2.list_files_added_or_updated
                        U.assert_eq(0, gc1_added_or_changed_file_list.size)
                        U.assert_eq(1, gc2_added_or_changed_file_list.size)
                        U.assert_eq("src/main/java/com/oracle/syseng/configuration/repository/IntegrationRepositoryImpl.java", gc2_added_or_changed_file_list[0])
                        cc1 = Cspec_set.from_s(<<-EOS)
                        {
                        "cspec": "#{TEST_REPO_SPEC};dc68aa99903505da966358f96c95f946901c664b",
                        "cspec_deps": [] }
                        EOS

                        cc2 = Cspec_set.from_s(<<-EOS)
                        {
                        "cspec": "#{TEST_REPO_SPEC};42f2d95f008ea14ea3bb4487dba8e3e74ce992a1",
                        "cspec_deps": []}
                        EOS

                        U.assert_eq(1, cc1.commits.size)
                        U.assert_eq(1, cc2.commits.size)
                        U.assert_eq(gc1, cc1.commits[0], "cc1 commit")
                        U.assert_eq(gc2, cc2.commits[0], "cc2 commit")
                        U.assert_eq([], cc2.find_commits_for_components_that_were_added_since(cc1), "cc2 added commits")
                        #U.assert_eq([], cc2.find_commits_for_components_that_were_removed_since(cc1), "cc2 removed commits")
                        U.assert_eq([], cc1.find_commits_for_components_that_were_added_since(cc2), "cc1 added commits")
                        #U.assert_eq([], cc1.find_commits_for_components_that_were_removed_since(cc2), "cc1 removed commits")
                        changed_commits1 = cc1.find_commits_for_components_that_changed_since(cc2)
                        changed_commits2 = cc2.find_commits_for_components_that_changed_since(cc1)
                        U.assert_eq(1, changed_commits1.size, 'cc1 size ck')
                        U.assert_eq(1, changed_commits2.size, 'cc2 size ck')
                        U.assert_eq(gc1, changed_commits1[0], 'gc1 json ck')
                        U.assert_eq(gc2, changed_commits2[0], 'gc2 json ck')
                        test_json
                        test_list_files_changed_since()
                end
        end
end

class Cspec_set < Error_holder
        attr_accessor :top_commit
        attr_accessor :dependency_commits

        def initialize(top_commit, dependency_commits)
                if top_commit.is_a?(String)
                        self.top_commit = Git_cspec.from_repo_and_commit_id(top_commit)
                else
                        self.top_commit = top_commit
                end
                self.dependency_commits = dependency_commits
        end
        def eql?(other)
                self.top_commit.eql?(other.top_commit) && dependency_commits.eql?(other.dependency_commits)
        end
        def to_json()
                h = Hash.new
                h["cspec"] = top_commit.repo_and_commit_id
                cspec_deps = []
                self.dependency_commits.each do | commit |
                        cspec_deps << commit.repo_and_commit_id
                end
                h["cspec_deps"] = cspec_deps
                JSON.pretty_generate(h)
        end
        def commits()
                z = []
                z << self.top_commit
                z = z.concat(self.dependency_commits)
                z
        end
        def list_files_changed_since(other_cspec_set)
                commits = list_changes_since(other_cspec_set)
                fss = File_sets.new
                commits.each do | commit |
                        fss.add_set(commit.list_changed_files)
                end
                return fss
        end
        def list_changes_since(other_cspec_set)
                pairs = get_pairs_of_commits_with_matching_repo(other_cspec_set)
                changes = []
                pairs.each do | pair |
                        commit0 = pair[0]
                        commit1 = pair[1]
                        changes += commit1.list_changes_since(commit0)
                end
                changes
        end
        def get_pairs_of_commits_with_matching_repo(other_cspec_set)
                pairs = []
                self.commits.each do | commit |
                        previous_commit_for_same_component = commit.find_commit_for_same_component(other_cspec_set)
                        if previous_commit_for_same_component
                                pairs << [ previous_commit_for_same_component, commit ]
                        end
                end
                pairs
        end
        def list_bug_IDs_since(other_cspec_set)
                changes = list_changes_since(other_cspec_set)
                bug_IDs = Git_cspec.grep_group1(changes, Cspec_set.bug_id_regexp)
                bug_IDs
        end
        def find_commits_for_components_that_were_added_since(other_cspec_set)
                commits_for_components_that_were_added = []
                self.commits.each do | commit |
                        if !commit.component_contained_by?(other_cspec_set)
                                commits_for_components_that_were_added << commit
                        end
                end
                commits_for_components_that_were_added
        end
        def find_commits_for_components_that_changed_since(other_cspec_set)
                commits_for_components_that_changed = []
                self.commits.each do | commit |
                        previous_commit_for_same_component = commit.find_commit_for_same_component(other_cspec_set)
                        if previous_commit_for_same_component
                                commits_for_components_that_changed << commit
                        end
                end
                commits_for_components_that_changed
        end
        def list_files_added_or_updated_since(other_cspec_set)
                commits_for_components_that_were_added   = self.find_commits_for_components_that_were_added_since(other_cspec_set)
                commits_which_were_updated               = self.find_commits_for_components_that_changed_since(other_cspec_set)

                added_files = []
                commits_for_components_that_were_added.each do | commit |
                        added_files += commit.list_files()
                end

                updated_files = []
                commits_which_were_updated.each do | commit |
                        updated_files += commit.list_files_added_or_updated()
                end
                added_files + updated_files
        end
        def to_s()
                z = "Cspec_set(#{self.top_commit}/["
                self.dependency_commits.each do | commit |
                        z << " " << commit.to_s
                end
                z << "]"
                z
        end
        class << self
                attr_accessor :bug_id_regexp_val

                def list_bug_IDs_between(cspec_set_s1, cspec_set_s2)
                        cspec_set1 = Cspec_set.from_repo_and_commit_id(cspec_set_s1)
                        cspec_set2 = Cspec_set.from_repo_and_commit_id(cspec_set_s2)
                        return cspec_set2.list_bug_IDs_since(cspec_set1)
                end
                def list_changes_between(cspec_set_s1, cspec_set_s2)
                        cspec_set1 = Cspec_set.from_repo_and_commit_id(cspec_set_s1)
                        cspec_set2 = Cspec_set.from_repo_and_commit_id(cspec_set_s2)
                        return cspec_set2.list_changes_since(cspec_set1)
                end
                def list_files_changed_between(cspec_set_s1, cspec_set_s2)
                        cspec_set1 = Cspec_set.from_repo_and_commit_id(cspec_set_s1)
                        cspec_set2 = Cspec_set.from_repo_and_commit_id(cspec_set_s2)
                        return cspec_set2.list_files_changed_since(cspec_set1)
                end
                def list_last_changes(repo_spec, n)
                        gr = Git_repo.new(repo_spec)
                        # Example log entry:
                        #
                        # "commit 22ab587dd9741430c408df1f40dbacd56c657c3f"
                        # "Author: osnbt on socialdev Jenkins <ade-generic-osnbt_ww@oracle.com>"
                        # "Date:   Tue Feb 20 09:28:24 2018 -0800"
                        # ""
                        # "    New version com.oracle.cecs.caas:manifest:1.0.3012, initiated by https://osnci.us.oracle.com/job/caas.build.pl.master/3012/"
                        # "    and updated (consumed) by https://osnci.us.oracle.com/job/serverintegration.deptrigger.pl.master/484/"
                        # "    "
                        # "    The deps.gradle file, component.properties and any other @autoupdate files listed in deps.gradle"
                        # "    have been automatically updated to consume these dynamic dependencies."
                        commit_log_entries = gr.system_as_list("git log --oneline -n #{n} --pretty=format:'%H:%s'")
                        commits = []
                        commit_log_entries.each do | commit_log_entry |
                                if commit_log_entry !~ /^([a-f0-9]+):(.*)$/m
                                        raise "could not understand #{commit_log_entry}"
                                else
                                        commit_id, comment = $1, $2
                                        commit = Git_cspec.new(gr, commit_id)
                                        commit.comment = comment
                                        commits << commit
                                end
                        end
                        commits
                end
                def bug_id_regexp()
                        if !Cspec_set.bug_id_regexp_val
                                z = Global.get("bug_id_regexp_val", ".*Bug (.*).*")
                                Cspec_set.bug_id_regexp_val = Regexp.new(z, "m")
                        end
                        Cspec_set.bug_id_regexp_val
                end
                def from_file(json_fn)
                        from_s(IO.read(json_fn))
                end
                def from_s(s, arg_name="Cspec_set.from_s")
                        if s.start_with?('http')
                                url = s
                                return from_s(U.rest_get(url), "#{arg_name} => #{url}")
                        end
                        deps = nil
                        if Git_cspec.is_repo_and_commit_id?(s)
                                repo_and_commit_id = s
                        else
                                if s !~ /\{/
                                        Error_holder.raise("expecting JSON, but I see no hash in #{s}", 400)
                                end
                                begin
                                        h = JSON.parse(s)
                                rescue JSON::ParserError => jpe
                                        Error_holder.raise("trouble parsing #{arg_name} \"#{s}\": #{jpe.to_s}", 400)
                                end
                                repo_and_commit_id = h["cspec"]
                                Error_holder.raise("expected a value for JSON key 'cspec' in #{s}", 400) unless repo_and_commit_id
                                if h.has_key?("cspec_deps")
                                        array_of_dep_cspec = h["cspec_deps"]
                                        deps = []
                                        array_of_dep_cspec.each do | dep_cspec |
                                                deps << Git_cspec.from_repo_and_commit_id(dep_cspec)
                                        end
                                end
                        end
                        if !deps
                                # executes auto-discovery in this case
                                return Cspec_set.from_repo_and_commit_id(repo_and_commit_id)
                        end
                        cs = Cspec_set.new(repo_and_commit_id, deps)
                        cs
                end
                def from_repo_and_commit_id(repo_and_commit_id, dependency_commits=nil)
                        top_commit = Git_cspec.from_repo_and_commit_id(repo_and_commit_id)
                        if !dependency_commits
                                dependency_commits = top_commit.unreliable_autodiscovery_of_dependencies_from_build_configuration
                        end
                        Cspec_set.new(top_commit, dependency_commits)
                end
                def test_list_changes_since()
                        compound_spec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;6b5ed0226109d443732540fee698d5d794618b64"
                        compound_spec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"
                        cc1 = Cspec_set.from_repo_and_commit_id(compound_spec1)
                        cc2 = Cspec_set.from_repo_and_commit_id(compound_spec2)

                        gc2 = Git_cspec.from_repo_and_commit_id(compound_spec2)

                        changes = cc2.list_changes_since(cc1)
                        changes2 = Cspec_set.list_changes_between(compound_spec1, compound_spec2)
                        U.assert_eq(changes, changes2, "vfy same result from wrapper 2a")

                        g1b = Git_cspec.from_repo_and_commit_id("git;git.osn.oraclecorp.com;osn/cec-server-integration;master;22ab587dd9741430c408df1f40dbacd56c657c3f")
                        g1a = Git_cspec.from_repo_and_commit_id("git;git.osn.oraclecorp.com;osn/cec-server-integration;master;7dfff5f400b3011ae2c4aafac286d408bce11504")

                        #U.assert_eq([gc2, g1b, g1a], changes)  # apparently array == gets resolved in terms of string comparisons; this fails here because the actual values have non-nil comment fields
                        U.assert_eq(gc2, changes[0], "test_list_changes_since.0")
                        U.assert_eq(g1b, changes[1], "test_list_changes_since.1")
                        U.assert_eq(g1a, changes[2], "test_list_changes_since.2")
                end
                def test_list_files_changed_since()
                        compound_spec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;6b5ed0226109d443732540fee698d5d794618b64"
                        compound_spec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"
                        cc1 = Cspec_set.from_repo_and_commit_id(compound_spec1)
                        cc2 = Cspec_set.from_repo_and_commit_id(compound_spec2)
             
                        changed_files = cc2.list_files_changed_since(cc1)
                        
                        changed_files2 = Cspec_set.list_files_changed_between(compound_spec1, compound_spec2)
                        U.assert_eq(changed_files, changed_files2, "vfy same result from wrapper 2b")
                        
                        expected_changed_files = {
                        "git;git.osn.oraclecorp.com;osn/cec-server-integration;master" => [ "component.properties", "deps.gradle"],
                        "git;git.osn.oraclecorp.com;ccs/caas;master" => [ "component.properties", "deps.gradle"]
                        }
                        
                        U.assert_json_eq(expected_changed_files, changed_files)
                end
                def test_list_bug_IDs_since()
                        # I noticed that for the commits in this range, there is a recurring automated comment "caas.build.pl.master/3013/" -- so
                        # I thought I would reset the pattern to treat that number like a bug ID for the purposes of the test.
                        # (At some point, i'll need to go find a comment that really does refer to a bug ID.)
                        saved_bug_id_regexp = Cspec_set.bug_id_regexp_val
                        begin
                                compound_spec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;6b5ed0226109d443732540fee698d5d794618b64"
                                compound_spec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"
                                gc1 = Cspec_set.from_repo_and_commit_id(compound_spec1)
                                gc2 = Cspec_set.from_repo_and_commit_id(compound_spec2)
                                Cspec_set.bug_id_regexp_val = Regexp.new(".*caas.build.pl.master/(\\d+)/.*", "m")
                                bug_IDs = gc2.list_bug_IDs_since(gc1)
                                U.assert_eq(["3013", "3012", "3011"], bug_IDs, "bug_IDs_since")
                        ensure
                                Cspec_set.bug_id_regexp_val = saved_bug_id_regexp
                        end
                end
                def test_json_export()
                        json = Cspec_set.from_s("git;git.osn.oraclecorp.com;osn/cec-server-integration;master;2bc0b1a58a9277e97037797efb93a2a94c9b6d99").to_json
                        U.assert_json_eq(%Q[{"cspec":"git;git.osn.oraclecorp.com;osn/cec-server-integration;master;2bc0b1a58a9277e97037797efb93a2a94c9b6d99","cspec_deps":["git;git.osn.oraclecorp.com;ccs/caas;master_external;2ec7af608aac74da543ce581de9b7e0de2e52dd3","git;git.osn.oraclecorp.com;osn/cef;master_external;aba07a5ac4b3ac2a0a4e9111d674c6bae2cab50c"]}], json, "Cspec_set.test_json_export")
                end
                def test()
                        test_json_export()
                        test_list_files_changed_since()
                        repo_spec = "git;git.osn.oraclecorp.com;osn/cec-server-integration;master"
                        valentine_commit_id = "2bc0b1a58a9277e97037797efb93a2a94c9b6d99"
                        cc = Cspec_set.from_repo_and_commit_id("#{repo_spec};#{valentine_commit_id}")
                        U.assert(cc.dependency_commits.size > 0, "cc.dependency_commits.size > 0")
                        json = cc.to_json
                        U.assert_json_eq('{"cspec":"git;git.osn.oraclecorp.com;osn/cec-server-integration;master;2bc0b1a58a9277e97037797efb93a2a94c9b6d99","cspec_deps":["git;git.osn.oraclecorp.com;ccs/caas;master_external;2ec7af608aac74da543ce581de9b7e0de2e52dd3","git;git.osn.oraclecorp.com;osn/cef;master_external;aba07a5ac4b3ac2a0a4e9111d674c6bae2cab50c"]}', json, "dependency_gather1")

                        cc2 = Cspec_set.from_s(json)
                        U.assert_eq(cc, cc2, "json copy dependency_gather1")

                        cc9 = Cspec_set.from_repo_and_commit_id("git;git.osn.oraclecorp.com;osn/cec-server-integration;;2bc0b1a58a9277e97037797efb93a2a94c9b6d99")
                        U.assert_json_eq(%Q[{"cspec": "git;git.osn.oraclecorp.com;osn/cec-server-integration;master;2bc0b1a58a9277e97037797efb93a2a94c9b6d99","cspec_deps": ["git;git.osn.oraclecorp.com;ccs/caas;master_external;2ec7af608aac74da543ce581de9b7e0de2e52dd3", "git;git.osn.oraclecorp.com;osn/cef;master_external;aba07a5ac4b3ac2a0a4e9111d674c6bae2cab50c"]}], cc9.to_json, "cc9.to_json")

                        test_list_changes_since()
                        test_list_bug_IDs_since()
                end
        end
end

class Change_tracker_app
        attr_accessor :json_fn1
        attr_accessor :json_fn2

        attr_accessor :v_info1
        attr_accessor :v_info2

        def usage(msg)
                puts "Usage: ruby change_mon_show.rb VERSION_JSON_FILE1 VERSION_JSON_FILE2: #{msg}"
                exit
        end
        def go()
                if !json_fn1
                        usage('no args seen')
                end
                if !json_fn2
                        usage('missing VERSION_JSON_FILE2')
                end
                cspec_set1 = Cspec_set.from_file(json_fn1)
                cspec_set2 = Cspec_set.from_file(json_fn2)
                cspec_set2.list_files_added_or_updated_since(cspec_set1).each do | changed_file |
                        puts changed_file
                end
        end
        class << self
        end
end

class Global < Error_holder
        class << self
                attr_accessor :data_json_fn
                attr_accessor :data
                def init_data()
                        if !data
                                if !data_json_fn
                                        data_json_fn = "/scratch/change_tracker/change_tracker.json"
                                end
                                if File.exist?(data_json_fn)
                                        self.data = Json_obj.new(IO.read(data_json_fn))
                                else
                                        self.data = Json_obj.new
                                end
                        end
                end
                def get(key, default_value = nil)
                        init_data
                        data.get(key, default_value)
                end
                def get_scratch_dir(key)
                        raise "bad key" unless key
                        scratch_dir_root = get("scratch_dir", "/scratch/change_tracker")
                        key = key.gsub(/[^\w]/, "_")
                        scratch_dir = scratch_dir_root + "/" + key
                        FileUtils.mkdir_p(scratch_dir)
                        scratch_dir
                end
                def has_key?(key)
                        data.has_key?(key)
                end
                def get_credentials(key, ok_if_nonexistent = false)
                        u_key = "#{key}.username"
                        pw_key = "#{key}.pw"
                        if has_key?(u_key)
                                return get(u_key), get(pw_key)
                        elsif ok_if_nonexistent
                                return nil
                        else
                                raise "cannot find credentials for #{key}"
                        end
                end
                def test()
                        U.assert_eq("test.val", Global.get("test.key"))
                        U.assert_eq("default val", Global.get("test.nonexistent_key", "default val"))
                        username, pw = Global.get_credentials("test_server")
                        U.assert_eq("some_username", username)
                        U.assert_eq("some_pw",       pw)
                end
        end
end

class Cec_gradle_parser < Error_holder
        def initialize()

        end
        class << self
                attr_accessor :trace_autodiscovery
                
                def to_dep_commits(gradle_deps_text, gr)
                        dependency_commits = []
                        gradle_deps_text.split(/\n/).grep(/^\s*manifest\s+"com./).each do | raw_manifest_line |

                                # raw_manifest_line=  manifest "com.oracle.cecs.caas:manifest:1.master_external.528"         //@trigger
                                puts "Cec_gradle_parser.to_dep_commits: raw_manifest_line=#{raw_manifest_line}" if trace_autodiscovery
                                
                                pom_url = Cec_gradle_parser.generate_manifest_url(raw_manifest_line)
                                puts "Cec_gradle_parser.to_dep_commits: resolved to pom_url=#{pom_url}" if trace_autodiscovery
                                pom_content = U.rest_get(pom_url)
                                puts "Cec_gradle_parser.to_dep_commits: ready to parse pom_content=#{pom_content}" if trace_autodiscovery
                                h = XmlSimple.xml_in(pom_content)
                                # {"git.repo.name"=>["caas.git"], "git.repo.branch"=>["master_external"], "git.repo.commit.id"=>["90f08f6882382e0134191ca2a993191c2a2f5b48"], "git.commit-id"=>["caas.git:90f08f6882382e0134191ca2a993191c2a2f5b48"], "jenkins.git-branch"=>["master_external"], "jenkins.build-url"=>["https://osnci.us.oracle.com/job/caas.build.pl.master_external/528/"], "jenkins.build-id"=>["2018-02-16_21:51:53"]}
                                puts %Q[Cec_gradle_parser.to_dep_commits: parsed pom xml, and seeing h["properties"][0]=#{h["properties"][0]}] if trace_autodiscovery

                                git_project_basename = h["properties"][0]["git.repo.name"][0] # e.g., caas.git
                                git_repo_branch = h["properties"][0]["git.repo.branch"][0]
                                git_repo_commit_id = h["properties"][0]["git.repo.commit.id"][0]

                                if git_project_basename == "caas.git"
                                        repo_name = "ccs/#{git_project_basename}"
                                else
                                        repo_name = "#{gr.get_project_name_prefix}/#{git_project_basename}"
                                end
                                repo_name.sub!(/.git$/, '')
                                repo_spec = Git_repo.make_spec(gr.source_control_server, repo_name, git_repo_branch)
                                dependency_commit = Git_cspec.new(repo_spec, git_repo_commit_id)
                                dependency_commits << dependency_commit
                                
                                puts "Cec_gradle_parser.to_dep_commits: dep repo_name=#{repo_name} (commit #{git_repo_commit_id}), resolved to dep #{dependency_commit}" if trace_autodiscovery

                                # jenkins.git-branch # master_external
                                # jenkins.build-url # https://osnci.us.oracle.com/job/infra.social.build.pl.master_external/270/
                                # jenkins.build-id # 270
                        end
                        if dependency_commits.empty?
                                raise "could not find deps in #{gradle_deps_text}"
                        end
                        dependency_commits
                end
                def generate_manifest_url(raw_manifest_line)
                        z = raw_manifest_line.sub(/  *manifest \"/, '')
                        z.sub!(/\/\/.*/, '')
                        z.sub!(/" *$/, '')

                        if z !~ /^(.*?):manifest:(\d+)\.([^\.]+)\.(\d+)$/
                                raise "could not understand #{z}"
                        end
                        package = $1
                        n1 = $2.to_i
                        branch = $3
                        n2 = $4.to_i

                        component = package.sub(/.*\./, '')

                        if branch == "master_internal"
                                top_package_components = "socialnetwork/#{component}"
                        else
                                top_package_components = "cecs/#{component}"
                        end
                        "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/#{top_package_components}/manifest/#{n1}.#{branch}.#{n2}/manifest-#{n1}.#{branch}.#{n2}.pom"
                end
                def test_manifest_parse(raw_manifest_line, expected_generated_manifest_url)
                        actual_generated_manifest_url = generate_manifest_url(raw_manifest_line)
                        pom_content = U.rest_get(actual_generated_manifest_url)
                        if pom_content =~ /"status" : 404,/
                                puts "I mapped the manifest line"
                                puts "\t#{raw_manifest_line}\nto\n\t#{actual_generated_manifest_url}"
                                if expected_generated_manifest_url =~ /^http/
                                        puts "but\n\t#{expected_generated_manifest_url}\nworks."
                                end
                                puts ""
                                puts ""
                                raise "did not find dependency for\n#{actual_generated_manifest_url}\nfrom\n#{raw_manifest_line}\n(#{pom_content})"
                        end
                        U.assert_eq(expected_generated_manifest_url, actual_generated_manifest_url)
                end
                def test()
                        test_manifest_parse("  manifest \"com.oracle.cecs.waggle:manifest:1.master_external.222\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/waggle/manifest/1.master_external.222/manifest-1.master_external.222.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.docs-server:manifest:1.master_external.94\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/docs-server/manifest/1.master_external.94/manifest-1.master_external.94.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.caas:manifest:1.master_external.53\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/caas/manifest/1.master_external.53/manifest-1.master_external.53.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.analytics:manifest:1.master_external.42\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/analytics/manifest/1.master_external.42/manifest-1.master_external.42.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.servercommon:manifest:1.master_external.74\"     //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/servercommon/manifest/1.master_external.74/manifest-1.master_external.74.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.waggle:manifest:1.master_external.270\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/waggle/manifest/1.master_external.270/manifest-1.master_external.270.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.docs-server:manifest:1.master_external.156\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/docs-server/manifest/1.master_external.156/manifest-1.master_external.156.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.caas:manifest:1.master_external.126\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/caas/manifest/1.master_external.126/manifest-1.master_external.126.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.analytics:manifest:1.master_external.84\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/analytics/manifest/1.master_external.84/manifest-1.master_external.84.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.servercommon:manifest:1.master_external.137\"     //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/servercommon/manifest/1.master_external.137/manifest-1.master_external.137.pom")
                        test_manifest_parse("  manifest \"com.oracle.cecs.pipeline-common:manifest:1.master_external.4\" //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/cecs/pipeline-common/manifest/1.master_external.4/manifest-1.master_external.4.pom")
                        test_manifest_parse("  manifest \"com.oracle.socialnetwork.pipeline-common:manifest:1.master_internal.55\" //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/socialnetwork/pipeline-common/manifest/1.master_internal.55/manifest-1.master_internal.55.pom")
                        test_manifest_parse("  manifest \"com.oracle.socialnetwork.webclient:manifest:1.master_internal.8103\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/socialnetwork/webclient/manifest/1.master_internal.8103/manifest-1.master_internal.8103.pom")
                        test_manifest_parse("  manifest \"com.oracle.socialnetwork.officeaddins:manifest:1.master_internal.161\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/socialnetwork/officeaddins/manifest/1.master_internal.161/manifest-1.master_internal.161.pom")
                        test_manifest_parse("  manifest \"com.oracle.socialnetwork.cef:manifest:1.master_internal.3790\"         //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/socialnetwork/cef/manifest/1.master_internal.3790/manifest-1.master_internal.3790.pom")
                        test_manifest_parse("  manifest \"com.oracle.socialnetwork.caas:manifest:1.master_internal.2364\"        //@trigger", "https://af.osn.oraclecorp.com/artifactory/internal-local/com/oracle/socialnetwork/caas/manifest/1.master_internal.2364/manifest-1.master_internal.2364.pom")
                end
        end
end
