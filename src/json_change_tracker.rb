require_relative 'u'
require_relative 'change_tracker'
require 'json'

class User_error < Exception
        attr_accessor :emsg
        def initialize(s)
                self.emsg = s
        end
end

class Json_change_tracker
        TEST_REPO_NAME = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;"
        attr_accessor :op
        attr_accessor :error

        def initialize()
                Json_change_tracker.init()
        end
        def exception()
                self.error
        end
        def get(h, key)
                if !h.has_key?(key)
                        self.error = User_error.new("did not find anything for key '#{key}'")
                        raise self
                end
                h[key]
        end
        def get_Compound_commit(h, cspec_key)
                cspec = get(h, cspec_key)
                deps_key = "#{cspec_key}_deps"
                if !h.has_key?(deps_key)
                        # executes auto-discovery in this case
                        return Compound_commit.from_spec(cspec)
                end
                array_of_dep_cspec = h[deps_key]
                deps = []
                array_of_dep_cspec.each do | dep_cspec |
                        deps << Git_commit.from_spec(dep_cspec)
                end
                puts "deps=#{deps}"
                Compound_commit.new(cspec, deps)
        end
        def get_Compound_commit_pair(h)
                cc1 = get_Compound_commit(h, "cspec1")
                cc2 = get_Compound_commit(h, "cspec2")
                return cc1, cc2
        end
        def usage(emsg)
                z = ''
                z << emsg << "\n"
                z << Json_change_tracker.examples(self.op)
                z
        end
        def system_error(emsg, backtrace=nil)
                # nicer formatting could be implemented here to make the error more presentable in the browser:
                z = "Error encountered: #{emsg}"
                if backtrace
                        z << "#{backtrace.join("\n")}\n"
                end

                z
        end
        def go(json_text)
                http_response_code = 200
                self.op = nil    # in case the parse fails...
                h = nil
                begin
                        h = JSON.parse(json_text)
                rescue JSON::ParserError => jpe
                        emsg = jpe.to_s
                end
                if !h
                        return 400, usage("trouble parsing \"#{json_text}\": #{emsg}")
                end
                begin
                        self.op = get(h, "op")
                        case self.op
                        when "list_bug_IDs_between"
                                cc1, cc2 = get_Compound_commit_pair(h)
                                x = cc2.list_bug_IDs_since(cc1)
                        when "list_changes_between"
                                cc1, cc2 = get_Compound_commit_pair(h)
                                x = cc2.list_changes_since(cc1)
                        when "list_files_changed_between"
                                cc1, cc2 = get_Compound_commit_pair(h)
                                x = cc2.list_files_changed_since(cc1)
                        else
                                return 400, usage("did not know how to interpret op '#{op}'")
                        end
                rescue Error_record => e_obj
                        return e_obj.http_response_code, system_error(e_obj.emsg)
                rescue RuntimeError => e_obj
                        # https://en.wikipedia.org/wiki/List_of_HTTP_status_codes
                        # 500 server error
                        # 501 not impl
                        return 500, system_error(e_obj.to_s, e_obj.backtrace)
                rescue User_error => e_obj
                        return 400, usage(e_obj.emsg)
                end
                z = nil
                x.each do | elt |
                        if !z
                                z = "[\n"
                        else
                                z << ",\n"
                        end
                        z << "\t" << elt.to_json
                end
                z << "\n]\n"
                return http_response_code, z
        end
        class << self
                attr_accessor :examples_by_op
                attr_accessor :usage_full_examples
                def init()
                        if !Json_change_tracker.examples_by_op
                                Json_change_tracker.examples_by_op = Hash.new
                                Json_change_tracker.examples_by_op["list_bug_IDs_between"] = "@@ example of list_bug_IDs_between\n"
                                Json_change_tracker.examples_by_op["list_changes_between"] = "@@ example of list_changes_between\n"
                                Json_change_tracker.examples_by_op["list_files_changed_between"] = "@@ example of list_files_changed_between\n"

                                z = ""
                                Json_change_tracker.examples_by_op.values.each do | example |
                                        z << example
                                end
                                Json_change_tracker.usage_full_examples = z
                                STDOUT.sync     # always flush immediately
                        end
                end
                def examples(example_op=nil)
                        init
                        z = "Example usage:\n"
                        if !example_op || !Json_change_tracker.examples_by_op.has_key?(example_op)
                                z << Json_change_tracker.usage_full_examples
                        else
                                z << Json_change_tracker.examples_by_op[example_op]
                        end
                        z
                end
                def test_assert_result_from_json(json, expected_result, title)
                        http_response_code, actual_result = Json_change_tracker.new.go(json)
                        U.assert_eq(200, http_response_code, "#{title} HTTP response code")
                        if !title
                                title = "from #{json}"
                        end
                        U.assert_json_eq(expected_result, actual_result, title)
                end
                def test_error_result_from_json(expected_http_response_code, json_input, expected_result, title)
                        actual_http_response_code, actual_result = Json_change_tracker.new.go(json_input)
                        
                        actual_result.gsub!(/:\d+:/, ":NNN:")
                        
                        U.assert_eq(expected_http_response_code, actual_http_response_code, "#{title} HTTP response code")
                        U.assert_eq(expected_result, actual_result, title)
                end
                def test_bad_json()
                        cspec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;;6b5ed0226109d443732540fee698d5d794618b64"
                        #cspec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"

                        test_error_result_from_json(400, %Q[{ "op" : "some_nonexistent_op" }], "did not know how to interpret op 'some_nonexistent_op'\n#{Json_change_tracker.examples}", "nonexistent op")
                        test_error_result_from_json(400, "whatever", "trouble parsing \"whatever\": 757: unexpected token at 'whatever'\n#{Json_change_tracker.examples}", "ridiculous null request")
                        test_error_result_from_json(400, %Q[{ "op" : "list_bug_IDs_between" }], "did not find anything for key 'cspec1'\n#{Json_change_tracker.examples("list_bug_IDs_between")}", "no cspec1")
                        test_error_result_from_json(400, %Q[{ "op" : "list_bug_IDs_between", "cspec1" : "#{cspec1}" }], "did not find anything for key 'cspec2'\n#{Json_change_tracker.examples("list_bug_IDs_between")}", "no cspec2")
                        test_error_result_from_json(400, %Q[{ "op" : "list_changes_between" }], "did not find anything for key 'cspec1'\n#{Json_change_tracker.examples("list_changes_between")}", "no cspec1 1")
                        test_error_result_from_json(400, %Q[{ "op" : "list_changes_between", "cspec1" : "#{cspec1}" }], "did not find anything for key 'cspec2'\n#{Json_change_tracker.examples("list_changes_between")}", "no cspec2 3")
                        test_error_result_from_json(400, %Q[{ "op" : "list_files_changed_between" }], "did not find anything for key 'cspec1'\n#{Json_change_tracker.examples("list_files_changed_between")}", "no cspec1 3")
                        test_error_result_from_json(400, %Q[{ "op" : "list_files_changed_between", "cspec1" : "#{cspec1}" }], "did not find anything for key 'cspec2'\n#{Json_change_tracker.examples("list_files_changed_between")}", "no cspec2 4")
                end
                def test_list_changes_close_neighbors()
                        cspec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;;6b5ed0226109d443732540fee698d5d794618b64"
                        cspec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"

                        z = %Q[{ "op" : "list_changes_between", "cspec1" : "#{cspec1}", "cspec2" : "#{cspec2}" }]
                        expected = %Q[[
                        {
                        "repo_spec": "git;git.osn.oraclecorp.com;osn/cec-server-integration;master;",
                        "commit_id": "06c85af5cfa00b0e8244d723517f8c3777d7b77e",
                        "comment": "New version com.oracle.cecs.caas:manifest:1.0.3013, initiated by https://osnci.us.oracle.com/job/caas.build.pl.master/3013/ and updated (consumed) by https://osnci.us.oracle.com/job/serverintegration.deptrigger.pl.master/485/"
                        },
                        {
                        "repo_spec": "git;git.osn.oraclecorp.com;osn/cec-server-integration;master;",
                        "commit_id": "22ab587dd9741430c408df1f40dbacd56c657c3f",
                        "comment": "New version com.oracle.cecs.caas:manifest:1.0.3012, initiated by https://osnci.us.oracle.com/job/caas.build.pl.master/3012/ and updated (consumed) by https://osnci.us.oracle.com/job/serverintegration.deptrigger.pl.master/484/"
                        },
                        {
                        "repo_spec": "git;git.osn.oraclecorp.com;osn/cec-server-integration;master;",
                        "commit_id": "7dfff5f400b3011ae2c4aafac286d408bce11504",
                        "comment": "New version com.oracle.cecs.caas:manifest:1.0.3011, initiated by https://osnci.us.oracle.com/job/caas.build.pl.master/3011/ and updated (consumed) by https://osnci.us.oracle.com/job/serverintegration.deptrigger.pl.master/483/"
                        },
                        {
                        "repo_spec": "git;git.osn.oraclecorp.com;ccs/caas;master;",
                        "commit_id": "a1466659536cf2225eadf56f43972a25e9ee1bed",
                        "comment": "New version com.oracle.cecs.docs-server:manifest:1.0.686, initiated by https://osnci.us.oracle.com/job/docs.build.pl.master/686/ and updated (consumed) by https://osnci.us.oracle.com/job/caas.deptrigger.pl.master/3008/"
                        },
                        {
                        "repo_spec": "git;git.osn.oraclecorp.com;ccs/caas;master;",
                        "commit_id": "b8563401dcd8576b14c91b7bbbd2aa23af9af406",
                        "comment": "New version com.oracle.cecs.docs-server:manifest:1.0.685, initiated by https://osnci.us.oracle.com/job/docs.build.pl.master/685/ and updated (consumed) by https://osnci.us.oracle.com/job/caas.deptrigger.pl.master/3007/"
                        },
                        {
                        "repo_spec": "git;git.osn.oraclecorp.com;ccs/caas;master;",
                        "commit_id": "89ce37a8745c11455366e46e509825d0ffc92489",
                        "comment": "New version com.oracle.cecs.docs-server:manifest:1.0.684, initiated by https://osnci.us.oracle.com/job/docs.build.pl.master/684/ and updated (consumed) by https://osnci.us.oracle.com/job/caas.deptrigger.pl.master/3006/"
                        }
                        ]]
                        test_assert_result_from_json(z, expected, "close neighbors list changes")
                end
                def test_nonexistent_codeline()
                        cspec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integrationXXXXX;;;6b5ed0226109d443732540fee698d5d794618b64"
                        cspec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"

                        z = %Q[{ "op" : "list_changes_between", "cspec1" : "#{cspec1}", "cspec2" : "#{cspec2}" }]
                        expected = %Q[Error encountered: error: bad exit code from
                        cd "/scratch/change_tracker/git/git.osn.oraclecorp.com/osn"; git clone  "git@git.osn.oraclecorp.com:osn/cec-server-integrationXXXXX.git"
                        GitLab: The project you were looking for could not be found.
                        fatal: The remote end hung up unexpectedly
                        
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/u.rb:NNN:in `block in system'
                        /opt/sensu/embedded/lib/ruby/2.0.0/open3.rb:NNN:in `popen_run'
                        /opt/sensu/embedded/lib/ruby/2.0.0/open3.rb:NNN:in `popen3'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/u.rb:NNN:in `system'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/change_tracker.rb:NNN:in `codeline_disk_write'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/change_tracker.rb:NNN:in `unreliable_autodiscovery_of_dependencies_from_build_configuration'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/change_tracker.rb:NNN:in `from_spec'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/json_change_tracker.rb:NNN:in `get_Compound_commit'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/json_change_tracker.rb:NNN:in `get_Compound_commit_pair'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/json_change_tracker.rb:NNN:in `go'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/json_change_tracker.rb:NNN:in `test_error_result_from_json'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/json_change_tracker.rb:NNN:in `test_nonexistent_codeline'
                        /net/slcipaq.us.oracle.com/scratch/nsproul/dp/git/change_tracker/src/json_change_tracker.rb:NNN:in `test'
                        cli_main.rb:NNN:in `<main>'
                        ]
                        test_error_result_from_json(500, z, expected, "nonexistent codeline")
                end
                def test()
                        test_nonexistent_codeline
                        test_bad_json
                        test_list_changes_close_neighbors
                end
        end
end
