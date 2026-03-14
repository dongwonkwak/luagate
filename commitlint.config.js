module.exports = {
  extends: ["@commitlint/config-conventional"],
  plugins: [
    {
      rules: {
        "header-match-linear-issue": ({ header }) => [
          /\[DON-\d+\]$/.test(header),
          "header must end with a Linear issue key, e.g. [DON-99]",
        ],
      },
    },
  ],
  rules: {
    "type-enum": [
      2,
      "always",
      ["feat", "fix", "docs", "refactor", "test", "chore", "perf"],
    ],
    "scope-enum": [
      1,
      "always",
      [
        "policy",
        "http",
        "stream",
        "admin",
        "ffi",
        "log",
        "metrics",
        "ci",
        "security",
        "lua",
        "scanner",
        "docker",
        "claude",
        "spec",
        "readme",
        "conventions",
        "progress",
        "hooks",
        "contributing",
      ],
    ],
    "subject-case": [0],
    "header-max-length": [2, "always", 100],
    "header-match-linear-issue": [2, "always"],
  },
};
