// Copyright (c) Microsoft. All rights reserved.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Formats.Tar;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Install_Scripts.Test.Utils;
using Xunit;

namespace Microsoft.DotNet.InstallationScript.Tests
{
    /// <summary>
    /// Tests for the HarmonyOS/OpenHarmony support in dotnet-install.sh.
    /// Unix-only because the script under test is the bash variant.
    /// </summary>
    public class HarmonyOsInstallScriptTests
    {
        [Fact]
        public void WhenTheMachineReportsHarmonyOS_TheLinkUsesTheOpenHarmonyRid()
        {
            Assert.SkipWhen(RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                "dotnet-install.sh tests are Unix-only.");

            using var fixture = new HarmonyOsFixture();

            CommandResult result = fixture.Run(
                "-dryrun",
                "-version", "11.0.100",
                "-azurefeed", "file://" + fixture.FeedPath);

            Assert.Equal(0, result.ExitCode);
            Assert.Contains("dotnet-sdk-11.0.100-openharmony-arm64.tar.gz", result.StdOut);
        }

        [Theory]
        [InlineData("harmonyos")]
        [InlineData("ohos")]
        [InlineData("openharmony")]
        public void WhenAnOpenHarmonyOsAliasIsPassed_TheLinkUsesTheOpenHarmonyRid(string osAlias)
        {
            Assert.SkipWhen(RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                "dotnet-install.sh tests are Unix-only.");

            using var fixture = new HarmonyOsFixture();

            CommandResult result = fixture.Run(
                "-dryrun",
                "-version", "11.0.100",
                "-os", osAlias,
                "-azurefeed", "file://" + fixture.FeedPath);

            Assert.Equal(0, result.ExitCode);
            Assert.Contains("openharmony-arm64", result.StdOut);
        }

        [Fact]
        public void WhenADirectUrlAndSha256ArePassed_TheArchiveIsInstalled()
        {
            Assert.SkipWhen(RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                "dotnet-install.sh tests are Unix-only.");

            using var fixture = new HarmonyOsFixture();

            CommandResult result = fixture.Run(
                "-url", "file://" + fixture.TarballPath,
                "-sha256", fixture.TarballSha256,
                "-version", "11.0.100",
                "-sign", "none",
                "-nopath",
                "-install-dir", fixture.InstallPath);

            Assert.Equal(0, result.ExitCode);
            Assert.True(File.Exists(Path.Combine(fixture.InstallPath, "sdk", "11.0.100", ".version")));
        }

        [Fact]
        public void WhenTheSha256DoesNotMatch_TheInstallFails()
        {
            Assert.SkipWhen(RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                "dotnet-install.sh tests are Unix-only.");

            using var fixture = new HarmonyOsFixture();

            CommandResult result = fixture.Run(
                "-url", "file://" + fixture.TarballPath,
                "-sha256", new string('0', 64),
                "-version", "11.0.100",
                "-sign", "none",
                "-nopath",
                "-install-dir", fixture.InstallPath);

            Assert.NotEqual(0, result.ExitCode);
            Assert.Contains("SHA-256 mismatch", result.StdOut + result.StdErr);
        }

        private sealed class HarmonyOsFixture : IDisposable
        {
            private readonly string _root;
            private readonly string _shimDir;

            public HarmonyOsFixture()
            {
                _root = Path.Combine(Path.GetTempPath(), "dotnet-ohos-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(_root);

                _shimDir = Path.Combine(_root, "shim");
                Directory.CreateDirectory(_shimDir);
                string unamePath = Path.Combine(_shimDir, "uname");
                File.WriteAllText(unamePath, "#!/bin/sh\ncase \"${1:-}\" in\n  -m) echo aarch64 ;;\n  -s) echo HarmonyOS ;;\n  *) echo HarmonyOS ;;\nesac\n");
                File.SetUnixFileMode(unamePath,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                    UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                    UnixFileMode.OtherRead | UnixFileMode.OtherExecute);

                FeedPath = Path.Combine(_root, "feed");
                string versionDir = Path.Combine(FeedPath, "Sdk", "11.0.100");
                Directory.CreateDirectory(versionDir);
                File.WriteAllText(Path.Combine(versionDir, "productVersion.txt"), "11.0.100\n");

                InstallPath = Path.Combine(_root, "install");
                TarballPath = Path.Combine(_root, "dotnet-sdk-11.0.100-openharmony-arm64.tar.gz");
                CreateTarball(TarballPath);
                TarballSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(TarballPath))).ToLowerInvariant();
            }

            public string FeedPath { get; }
            public string InstallPath { get; }
            public string TarballPath { get; }
            public string TarballSha256 { get; }

            public CommandResult Run(params string[] args)
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = "/bin/bash",
                    Arguments = $"{GetScriptPath()} {ArgumentEscaper.EscapeAndConcatenateArgArrayForProcessStart(args)}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                startInfo.Environment["PATH"] = _shimDir + Path.PathSeparator + Environment.GetEnvironmentVariable("PATH");
                startInfo.Environment["TMPDIR"] = _root;

                using Process process = Process.Start(startInfo)!;
                string stdout = process.StandardOutput.ReadToEnd();
                string stderr = process.StandardError.ReadToEnd();
                process.WaitForExit();

                return new CommandResult(process.ExitCode, stdout, stderr);
            }

            private static string GetScriptPath()
            {
                string? directory = AppContext.BaseDirectory;
                while (directory != null && !Directory.Exists(Path.Combine(directory, ".git")))
                {
                    directory = Directory.GetParent(directory)?.FullName;
                }

                if (directory == null)
                {
                    throw new InvalidOperationException("Could not locate the repository root.");
                }

                return Path.Combine(directory, "src", "dotnet-install.sh");
            }

            private static void CreateTarball(string destination)
            {
                using FileStream file = File.Create(destination);
                using var gzip = new GZipStream(file, CompressionMode.Compress);
                using var writer = new TarWriter(gzip, TarEntryFormat.Pax);
                AddEntry(writer, "sdk/", null);
                AddEntry(writer, "sdk/11.0.100/", null);
                AddEntry(writer, "sdk/11.0.100/.version", "11.0.100\n");
                AddEntry(writer, "sdk/11.0.100/fake.txt", "fake payload\n");
            }

            private static void AddEntry(TarWriter writer, string name, string? content)
            {
                if (content == null)
                {
                    writer.WriteEntry(new PaxTarEntry(TarEntryType.Directory, name));
                }
                else
                {
                    var entry = new PaxTarEntry(TarEntryType.RegularFile, name)
                    {
                        DataStream = new MemoryStream(Encoding.UTF8.GetBytes(content))
                    };
                    writer.WriteEntry(entry);
                }
            }

            public void Dispose()
            {
                try
                {
                    Directory.Delete(_root, true);
                }
                catch
                {
                    // Best effort cleanup.
                }
            }
        }

        private sealed record CommandResult(int ExitCode, string StdOut, string StdErr);
    }
}
