@testset "CI Rust companion selection" begin
    if Sys.iswindows()
        @test_skip "CI selection runs under bash on Linux"
    else
        workflow = read(joinpath(@__DIR__, "..", ".github", "workflows", "CI.yml"), String)
        selection = split(split(workflow, "      - name: Select powerio branch\n"; limit=2)[2],
                          "      - name: Check out powerio\n"; limit=2)[1]
        script = split(selection, "        run: |\n"; limit=2)[2]
        script = replace(script, r"(?m)^          " => "")

        function select_ref(; pin=nothing, fallback="main", available=String[])
            mktempdir() do dir
                mkdir(joinpath(dir, ".github"))
                pin === nothing || write(joinpath(dir, ".github", "powerio-ref"), pin)
                fallback === nothing || write(joinpath(dir, ".github", "powerio-companion"), fallback)
                bin = mkdir(joinpath(dir, "bin"))
                mock_git = joinpath(bin, "git")
                write(mock_git, """
                #!/usr/bin/env bash
                for ref in \$AVAILABLE_REFS; do
                    if [ "\${!#}" = "\$ref" ]; then exit 0; fi
                done
                exit 2
                """)
                chmod(mock_git, 0o755)
                selector = joinpath(dir, "select.sh")
                write(selector, script)
                output = joinpath(dir, "output")
                write(output, "")
                env = copy(ENV)
                env["PATH"] = bin * ":" * env["PATH"]
                env["POWERIO_BRANCH"] = "codex/stale-companion"
                env["POWERIO_TOKEN"] = ""
                env["AVAILABLE_REFS"] = join(available, " ")
                env["GITHUB_OUTPUT"] = output
                process = run(pipeline(ignorestatus(setenv(Cmd(`bash -e $selector`; dir=dir), env));
                                       stdout=devnull, stderr=devnull))
                return success(process), read(output, String)
            end
        end

        pin = "0123456789abcdef0123456789abcdef01234567"
        @test select_ref(pin=pin, available=["codex/stale-companion"]) == (true, "ref=$pin\n")
        @test select_ref(pin="\n$pin\n") == (true, "ref=$pin\n")
        @test select_ref(pin="not-a-sha", available=["codex/stale-companion", "main"]) == (false, "")
        @test select_ref(pin="", available=["main"]) == (false, "")
        @test select_ref(available=["codex/stale-companion", "main"]) ==
              (true, "ref=codex/stale-companion\n")
        @test select_ref(available=["main"]) == (true, "ref=main\n")
        @test select_ref(fallback="other", available=["other"]) == (true, "ref=other\n")
        @test select_ref(fallback=nothing) == (true, "ref=main\n")
    end
end
