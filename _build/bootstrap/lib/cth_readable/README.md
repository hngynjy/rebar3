# `cth_readable`

An OTP library to be used for CT log outputs you want to be readable
around all that noise they contain.

There are currently the following hooks:

1. `cth_readable_shell`, which shows failure stacktraces in the shell and
   otherwise shows successes properly, in color.
2. `cth_readable_failonly`, which only outputs error and SASL logs to the
   shell in case of failures. It also provides `cthr:pal/1-4` functions,
   working like `ct:pal/1-4`, but being silenceable by that hook. A parse
   transform exists to automatically convert `ct:pal/1-3` into `cthr:pal/1-3`.
   Also automatically handles lager.
3. `cth_readable_nosasl`, which disables all SASL logging. It however requires
   to be run *before* `cth_readable_failonly` to work.

## What it looks like

![example](http://i.imgur.com/dDFNxZr.png)
![example](http://i.imgur.com/RXZBG7H.png)

## Usage with rebar3

Supported and enabled by default.

## Usage with  rebar2.x

Add the following to your `rebar.config`:

```erlang
{deps, [
    {cth_readable, {git, "https://github.com/ferd/cth_readable.git", {tag, "v1.1.0"}}}
    ]}.

{ct_opts, [{ct_hooks, [cth_readable_failonly, cth_readable_shell]}]}.
{ct_compile_opts, [{parse_transform, cth_readable_transform}]}.
```

## Usage with lager

If your lager handler has a custom formatter and you want that formatter
to take effect, rather than using a configuration such as:

```erlang
{lager, [
  {handlers, [{lager_console_backend,
                [info, {custom_formatter, [{app, "some-val"}]}]}
             ]}
]}.
```

Use:

```erlang
{lager, [
  {handlers, [{cth_readable_lager_backend,
                [info, {custom_formatter, [{app, "some-val"}]}]}
             ]}
]}.
```

It will let you have both proper formatting and support for arbitrary
configurations.

## Changelog
1.2.3:
- correct `syntax_lib` to `syntax_tools` as an app dependency

1.2.2:
- fix output for assertions

1.2.1:
- handle failures of parse transforms by just ignoring the culprit files.

1.2.0:
- move to `cf` library for color output, adding support for 'dumb' terminals

1.1.1:
- fix typo of `poplist -> proplist`, thanks to @egobrain

1.1.0:
- support for better looking EUnit logs
- support for lager backends logging to HTML files

1.0.1:
- support for CT versions in Erlang copies older than R16

1.0.0:
- initial stable release
