-- Unused, using snacks picker
return {
  {
    "ibhagwan/fzf-lua",
    opts = {
      fzf_opts = {
        ["--layout"] = "default",
        ["--cycle"] = true,
      },

      files = {
        resume = true,
        cwd_prompt = true,
        cwd_header = true,
      },
      grep = {
        multiprocess = true,
        rg_glob = true,
        glob_flag = "--iglob",
        glob_separator = "%s%-%-",
        resume = true,
        cwd_prompt = true,
        debug = true,
      },
    },
  },
}
