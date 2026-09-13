using System.Diagnostics;
using System.Globalization;
using System.IO.MemoryMappedFiles;
using System.IO.Pipes;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace NikkeLocalLab.Phase3B2.LocalBootstrap;

internal static class Program
{
    private const string AccountHost = "li-sg.intlgame.com";
    private const string AuthHost = "aws-na.intlgame.com";
    private const string AccountSdkKey = "fbdb256e459ddcb8cd2acfe1b62d63ed";
    private const string IntlSdkKey = "3d0ef5272bf6bc22fd484c18d96be5c0";
    private const ulong GameId = 29080;

#if RESOURCE_PROBE_BOOTSTRAP
    private const string BootstrapModeCode = "bounded_resource_probe_bootstrap";
    private const string StartContractId = "nll/resource-probe-bootstrap-start/v1";
    private const string ExitContractId = "nll/resource-probe-bootstrap-exit/v1";
    private const string FailureContractId = "nll/resource-probe-bootstrap-failure/v1";
    private static ResourceProbeBootstrapSettings? probeSettings;
#elif PHYSICAL_BOOTSTRAP
    private const string BootstrapModeCode =
        "source_built_sail_abi_physical_clone_bootstrap";
    private const string StartContractId =
        "nll/phase3b2-physical-bootstrap-client-start/v1";
    private const string ExitContractId =
        "nll/phase3b2-physical-bootstrap-client-exit/v1";
    private const string FailureContractId =
        "nll/phase3b2-physical-bootstrap-failure/v1";
#else
    private const string BootstrapModeCode =
        "source_built_sail_abi_local_bootstrap";
    private const string StartContractId =
        "nll/phase3b2-local-bootstrap-client-start/v1";
    private const string ExitContractId =
        "nll/phase3b2-local-bootstrap-client-exit/v1";
    private const string FailureContractId =
        "nll/phase3b2-local-bootstrap-failure/v1";
#endif

    private static readonly JsonSerializerOptions ReceiptJsonOptions = new()
    {
        WriteIndented = true,
    };

    public static async Task<int> Main(string[] args)
    {
#if RESOURCE_PROBE_BOOTSTRAP
        if (args is not ([] or ["--inspect-probe-inputs"])) return 64;
        try { probeSettings = ResourceProbeBootstrapSettings.Load(); }
        catch { Console.WriteLine("resource_probe_bootstrap_inputs_rejected"); return 64; }
        if (args is ["--inspect-probe-inputs"])
        {
            Console.WriteLine("{\"status\":\"probe_bootstrap_inputs_verified_not_started\",\"clientStarted\":false,\"authenticationStarted\":false}");
            return 0;
        }
        var assessmentUid = probeSettings.AssessmentUid;
        var contextPath = probeSettings.ContextPath;
        var runRoot = probeSettings.RunRoot;
        var clientPath = probeSettings.ClientPath;
        var resourcePath = probeSettings.ResourcePath;
        using var probeLifetime = new CancellationTokenSource(TimeSpan.FromSeconds(probeSettings.DurationSeconds));
        Process? ownedClient = null;
#elif PHYSICAL_BOOTSTRAP
        var assessmentUid = Environment.GetEnvironmentVariable(
            "NLL_PHASE3B2_ASSESSMENT_UID") ?? string.Empty;
        var evidenceLane = Environment.GetEnvironmentVariable(
            "NLL_PHASE3B2_EVIDENCE_LANE") ?? "p2-client-start-v1";
        if (evidenceLane is not ("p2-client-start-v1" or "p2-client-start-v2"))
        {
            return 64;
        }
        var trustedRoot = @"C:\NLL\Evidence\Phase3B2\Physical";
        var contextPath = Path.Combine(
            trustedRoot, "server-profile-v1", "identity", "synthetic-context.json");
        var runRoot = Path.Combine(
            trustedRoot, evidenceLane, assessmentUid);
#if PHASE_D_151_CLIENT
        var clientPath =
            @"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke.exe";
        var resourcePath =
            @"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\Unity\com_proximabeta_NIKKE\";
#else
        var clientPath =
            @"C:\NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe";
        var resourcePath =
            @"C:\NLL\Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\";
#endif
#else
        var assessmentUid = Environment.GetEnvironmentVariable(
            "NLL_PHASE3B2_ASSESSMENT_UID") ?? string.Empty;
        var trustedRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "NikkeLocalLab", "Evidence", "Phase3B2", "Trusted");
        var contextPath = Path.Combine(trustedRoot, "identity", "synthetic-context.json");
        var runRoot = Path.Combine(trustedRoot, "reference-local-bootstrap-v1");
        var clientPath = @"E:\NIKKE\game\nikke.exe";
        var resourcePath = @"E:\Unity\com_proximabeta_NIKKE\";
#endif
        var startReceiptPath = Path.Combine(runRoot, "bootstrap-start.receipt.json");
        var exitReceiptPath = Path.Combine(runRoot, "bootstrap-exit.receipt.json");
        var failureReceiptPath = Path.Combine(runRoot, "bootstrap-failure.receipt.json");
        var sailPath = Path.Combine(AppContext.BaseDirectory, "sail_api_impl64.dll");

        Directory.CreateDirectory(runRoot);
        var stageCode = "cold_start_validation";
        try
        {
            Require(Guid.TryParse(assessmentUid, out _),
                "assessment_uid_invalid");
            Require(File.Exists(contextPath), "synthetic_context_missing");
            Require(File.Exists(clientPath), "client_executable_missing");
            Require(Directory.Exists(resourcePath), "client_resource_path_missing");
            Require(File.Exists(sailPath), "sail_abi_shim_missing");
            Require(!File.Exists(startReceiptPath) &&
                !File.Exists(exitReceiptPath) &&
                !File.Exists(failureReceiptPath),
                "bootstrap_evidence_already_exists");

            using var contextDocument = JsonDocument.Parse(
                await File.ReadAllTextAsync(contextPath, Encoding.UTF8));
            var context = contextDocument.RootElement;
            var username = RequiredString(context, "username");
            var password = RequiredString(context, "password");
            Require(username.StartsWith("synthetic-", StringComparison.Ordinal),
                "synthetic_username_invalid");
            Require(password.Length == 20, "synthetic_password_shape_invalid");

            stageCode = "local_account_login";
            var passwordHash = Md5Lower(password);
#if RESOURCE_PROBE_BOOTSTRAP
            stageCode = "local_synthetic_registration";
            using (var registration = await PostSignedAsync(AccountHost, "/account/register?seq=synthetic-probe",
                JsonSerializer.Serialize(new { account = username, password = passwordHash }), includeSdk: false))
                Require(ReadInt32(registration.RootElement, "ret") == 0, "probe_synthetic_registration_failed");
            stageCode = "local_account_login";
#endif
            using var accountResponse = await PostAccountLoginAsync(username, passwordHash);
            var accountRoot = accountResponse.RootElement;
            Require(ReadInt32(accountRoot, "ret") == 0,
                "local_account_login_rejected");
            var accountToken = RequiredString(accountRoot, "token");
            var accountUid = RequiredString(accountRoot, "uid");
            Require(accountToken.StartsWith("v4.local.", StringComparison.Ordinal),
                "local_account_token_family_invalid");

            stageCode = "local_intl_authentication";
            using var authResponse = await PostIntlAuthenticationAsync(
                username, accountUid, accountToken);
            var authRoot = authResponse.RootElement;
            Require(ReadInt32(authRoot, "ret") == 0,
                "local_intl_authentication_rejected");
            Require(RequiredString(authRoot, "openid") == accountUid,
                "local_intl_identity_mismatch");
            var loginData = BuildGameLoginData(authRoot);

            // Raw synthetic credentials and tokens are held only in this process.
            username = string.Empty;
            password = string.Empty;
            passwordHash = string.Empty;
            accountToken = string.Empty;
            accountUid = string.Empty;

#if RESOURCE_PROBE_BOOTSTRAP
            if (probeSettings.AuthOnly)
            {
                await WriteReceiptAsync(Path.Combine(runRoot, "auth-smoke.receipt.json"), new Dictionary<string, object?>
                {
                    ["contractId"] = "nll/resource-probe-auth-smoke/v1",
                    ["assessmentUid"] = assessmentUid,
                    ["localSyntheticAuthAccepted"] = true,
                    ["clientExecutionStarted"] = false,
                    ["nativeAdmission"] = "not_evaluated",
                });
                return 0;
            }
#endif

            stageCode = "sail_abi_bootstrap";
            var pipePayload = BuildPipePayload(resourcePath, loginData);
            loginData = string.Empty;
            using var sharedMemory = CreateSailSharedMemory();
            Process client;
            using (var pipe = new NamedPipeServerStream(
                "goodpipe", PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous))
            {
                var pipeTask = ServePipeOnceAsync(pipe, pipePayload);
#if NATIVE_FX_PROBE
                ExecutionTokenObservation.WriteNew(Path.Combine(runRoot, "client-start-before.private.json"),
                    new Dictionary<string, object?>
                    {
                        ["assessmentUid"] = assessmentUid,
                        ["observedAtUtc"] = UtcNowText(),
                        ["callingContext"] = ExecutionTokenObservation.Current(),
                        ["useShellExecute"] = false,
                        ["tokenMutationPerformed"] = false,
                    });
#endif
                client = Process.Start(new ProcessStartInfo
                {
                    FileName = clientPath,
                    WorkingDirectory = Path.GetDirectoryName(clientPath)!,
                    UseShellExecute = false,
#if NATIVE_FX_PROBE
                    Arguments = "-logFile \"" + Path.Combine(runRoot, "client.private.log") + "\"",
#endif
                }) ?? throw new ControlledFailure("client_process_start_failed");
#if RESOURCE_PROBE_BOOTSTRAP
                ownedClient = client;
#endif
#if NATIVE_FX_PROBE
                ExecutionTokenObservation.WriteNew(Path.Combine(runRoot, "client-start-after.private.json"),
                    new Dictionary<string, object?>
                    {
                        ["assessmentUid"] = assessmentUid,
                        ["observedAtUtc"] = UtcNowText(),
                        ["callingContext"] = ExecutionTokenObservation.Current(),
                        ["returnedChild"] = ExecutionTokenObservation.Child(client),
                        ["tokenMutationPerformed"] = false,
                    });
#endif

                var first = await Task.WhenAny(
                    pipeTask,
                    client.WaitForExitAsync(),
#if RESOURCE_PROBE_BOOTSTRAP
                    Task.Delay(Timeout.InfiniteTimeSpan, probeLifetime.Token));
#else
                    Task.Delay(TimeSpan.FromSeconds(90)));
#endif
                if (first != pipeTask)
                {
                    if (!client.HasExited)
                    {
                        client.Kill(entireProcessTree: true);
                        await client.WaitForExitAsync();
                    }
                    throw new ControlledFailure("sail_pipe_connection_not_observed");
                }
                await pipeTask;
                pipePayload.AsSpan().Clear();
            }

            await WriteReceiptAsync(startReceiptPath, new Dictionary<string, object?>
            {
                ["contractId"] = StartContractId,
                ["startedAtUtc"] = UtcNowText(),
                ["assessmentUid"] = assessmentUid,
                ["bootstrapModeCode"] = BootstrapModeCode,
                ["accountLoginAccepted"] = true,
                ["intlAuthenticationAccepted"] = true,
                ["tokenFamilyCode"] = "paseto_v4_local",
                ["sailSharedMemoryCreated"] = true,
                ["sailNamedPipeConnected"] = true,
                ["sailNamedPipePayloadWritten"] = true,
                ["sailNamedPipeClosedAfterPayload"] = true,
                ["sailPayloadClearedAfterWrite"] = true,
                ["sailSharedMemoryRetainedForClientLifetime"] = true,
                ["sailHandoffLifecycleCode"] =
                    "payload_then_pipe_eof_shared_memory_retained",
                ["clientProcessCount"] = 1,
                ["clientProcessId"] = client.Id,
                ["clientProcessObservationSourceCode"] =
                    "process_start_returned_pid",
                ["clientExecutionStarted"] = true,
                ["officialLauncherExecutionStarted"] = false,
                ["antiCheatSubstitutionApplied"] = false,
                ["officialIdentityPersisted"] = false,
                ["officialCredentialPersisted"] = false,
                ["nextStepCode"] = "observe_original_client_loading_login_lobby",
            });

#if RESOURCE_PROBE_BOOTSTRAP
            await client.WaitForExitAsync(probeLifetime.Token);
#else
            await client.WaitForExitAsync();
#endif
            await WriteReceiptAsync(exitReceiptPath, new Dictionary<string, object?>
            {
                ["contractId"] = ExitContractId,
                ["exitedAtUtc"] = UtcNowText(),
                ["assessmentUid"] = assessmentUid,
                ["clientProcessId"] = client.Id,
                ["clientExitCode"] = client.ExitCode,
                ["clientExecutionStarted"] = true,
                ["officialLauncherExecutionStarted"] = false,
                ["officialIdentityPersisted"] = false,
                ["officialCredentialPersisted"] = false,
            });
            return client.ExitCode;
        }
        catch (Exception exception)
        {
            var reasonCode = exception is ControlledFailure controlled
                ? controlled.Message
                : "bootstrap_unexpected_failure";
            if (!File.Exists(failureReceiptPath))
            {
                await WriteReceiptAsync(failureReceiptPath,
                    new Dictionary<string, object?>
                    {
                        ["contractId"] = FailureContractId,
                        ["failedAtUtc"] = UtcNowText(),
                        ["assessmentUid"] = assessmentUid,
                        ["failedStageCode"] = stageCode,
                        ["reasonCode"] = reasonCode,
#if RESOURCE_PROBE_BOOTSTRAP
                        // Types/codes only: exception messages can contain private routes or payload.
                        ["exceptionType"] = exception.GetType().FullName,
                        ["exceptionHresult"] = exception.HResult,
                        ["innerExceptionType"] = exception.InnerException?.GetType().FullName,
                        ["httpRequestError"] = (exception as HttpRequestException)?.HttpRequestError.ToString(),
                        ["httpStatus"] = (int?)(exception as HttpRequestException)?.StatusCode,
#endif
                        ["rawSecretEmitted"] = false,
                        ["officialLauncherExecutionStarted"] = false,
                        ["officialIdentityPersisted"] = false,
                        ["officialCredentialPersisted"] = false,
                    });
            }
            return 1;
        }
#if RESOURCE_PROBE_BOOTSTRAP
        finally
        {
            if (ownedClient is not null)
            {
                if (!ownedClient.HasExited)
                {
                    ownedClient.Kill(entireProcessTree: true);
                    await ownedClient.WaitForExitAsync();
                }
                ownedClient.Dispose();
            }
        }
#endif
    }

    private static async Task<JsonDocument> PostAccountLoginAsync(
        string username, string passwordHash)
    {
        var body = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["device_info"] = DeviceInfo(),
            ["extra_json"] = string.Empty,
            ["account"] = username,
            ["account_type"] = 1,
            ["password"] = passwordHash,
            ["phone_area_code"] = string.Empty,
            ["support_captcha"] = 0,
        });
        const string route = "/account/login?account_plat_type=131" +
            "&app_id=09af79d65d6e4fdf2d2569f0d365739d&lang_type=en&os=5";
        return await PostSignedAsync(AccountHost, route, body, includeSdk: false);
    }

    private static async Task<JsonDocument> PostIntlAuthenticationAsync(
        string username, string uid, string token)
    {
        var channelInfo = new Dictionary<string, object?>
        {
            ["openid"] = uid,
            ["token"] = token,
            ["account_type"] = 1,
            ["account"] = username,
            ["phone_area_code"] = string.Empty,
            ["account_plat_type"] = 131,
            ["lang_type"] = "en",
            ["is_login"] = true,
            ["account_uid"] = uid,
            ["account_token"] = token,
        };
        var body = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["channel_info"] = channelInfo,
            ["device_info"] = DeviceInfo(),
            ["channel_dis"] = "Windows",
            ["login_extra_info"] = "{}",
            ["lang_type"] = "en",
        });
        const string route = "/v2/auth/login?channelid=131&gameid=29080&os=5";
        return await PostSignedAsync(AuthHost, route, body, includeSdk: true);
    }

    private static async Task<JsonDocument> PostSignedAsync(
        string host, string route, string body, bool includeSdk)
    {
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var query = route;
        if (includeSdk)
        {
            query += "&sdk_version=1.24.00.873";
        }
        query += $"&seq=29080-{Guid.NewGuid():D}-{timestamp}-10";
        if (includeSdk)
        {
            query += $"&source=&ts={timestamp}";
        }
        query += "&sig=" + Md5Lower(query + body +
            (includeSdk ? IntlSdkKey : AccountSdkKey));

#if RESOURCE_PROBE_BOOTSTRAP
        using var client = probeSettings!.CreateClient();
#else
        using var handler = new HttpClientHandler();
        using var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(15),
        };
#endif
        client.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("*/*"));
        using var content = new StringContent(body, Encoding.UTF8, "application/json");
        using var response = await client.PostAsync($"https://{host}{query}", content);
        response.EnsureSuccessStatusCode();
        var bytes = await response.Content.ReadAsByteArrayAsync();
        Require(bytes.Length is > 0 and <= 1_048_576,
            "local_auth_response_size_invalid");
        return JsonDocument.Parse(bytes);
    }

    private static Dictionary<string, object?> DeviceInfo() => new()
    {
        ["guest_id"] = string.Empty,
        ["lang_type"] = "en",
        ["root_info"] = string.Empty,
        ["app_version"] = "0.0.6.566(0.0.6.566)",
        ["screen_dpi"] = string.Empty,
        ["screen_height"] = 0,
        ["screen_width"] = 0,
        ["device_brand"] = string.Empty,
        ["device_model"] = string.Empty,
        ["network_type"] = 0,
        ["ram_total"] = 0,
        ["rom_total"] = 0,
        ["cpu_name"] = string.Empty,
        ["client_region"] = string.Empty,
        ["vm_type"] = string.Empty,
        ["xwid"] = string.Empty,
        ["new_xwid"] = string.Empty,
        ["xwid_flag"] = string.Empty,
        ["cpu_arch"] = string.Empty,
    };

    private static string BuildGameLoginData(JsonElement auth)
    {
        var channelInfo = auth.TryGetProperty("channel_info", out var channel)
            ? channel.GetRawText()
            : "{}";
        var document = new Dictionary<string, object?>
        {
            ["ret"] = 0,
            ["msg"] = string.Empty,
            ["method_id"] = 0,
            ["ret_code"] = 0,
            ["ret_msg"] = string.Empty,
            ["extra_json"] = "{}",
            ["openid"] = RequiredString(auth, "openid"),
            ["token_expire_time"] = ReadInt32(auth, "token_expire_time"),
            ["first_login"] = ReadInt32(auth, "first_login"),
            ["reg_channel_dis"] = "Windows",
            ["user_name"] = ReadString(auth, "user_name"),
            ["picture_url"] = ReadString(auth, "picture_url"),
            ["need_name_auth"] = ReadBoolean(auth, "need_name_auth"),
            ["channel_info"] = channelInfo,
            ["bind_list"] = string.Empty,
            ["confirm_code"] = string.Empty,
            ["confirm_code_expire_time"] = 0,
            ["channelid"] = 131,
            ["token"] = RequiredString(auth, "token"),
            ["gender"] = ReadInt32(auth, "gender"),
            ["birthday"] = ReadString(auth, "birthday"),
            ["pf"] = ReadString(auth, "pf"),
            ["pf_key"] = ReadString(auth, "pf_key"),
            ["legal_doc"] = string.Empty,
            ["email"] = ReadString(auth, "email"),
            ["del_account_status"] = ReadInt32(auth, "del_account_status"),
            ["del_account_info"] = ReadString(auth, "del_account_info"),
            ["del_li_account_status"] = -1,
            ["transfer_code"] = string.Empty,
            ["transfer_code_expire_time"] = 0,
            ["channel"] = "LevelInfinite",
            ["link_li_token"] = string.Empty,
            ["link_li_uid"] = string.Empty,
            ["oauth_code"] = string.Empty,
            ["user_status"] = -1,
        };
        return JsonSerializer.Serialize(document);
    }

    private static byte[] BuildPipePayload(string resourcePath, string loginData)
    {
        using var stream = new MemoryStream();
        stream.WriteByte(0);
        stream.Write(Encoding.UTF8.GetBytes(resourcePath));
        stream.WriteByte(0);
        stream.Write(Encoding.UTF8.GetBytes(loginData));
        stream.WriteByte(0);
        stream.WriteByte(0);
        return stream.ToArray();
    }

    private static MemoryMappedFile CreateSailSharedMemory()
    {
        var file = MemoryMappedFile.CreateNew($"Sail.SharedMemory.{GameId}", 0x1000);
        using var view = file.CreateViewAccessor();
        view.Write(0, GameId);
        var directoryBytes = Encoding.Unicode.GetBytes(AppContext.BaseDirectory);
        Require(directoryBytes.Length + 10 < 0x1000,
            "bootstrap_directory_path_too_long");
        view.WriteArray(8, directoryBytes, 0, directoryBytes.Length);
        view.Write(8 + directoryBytes.Length, (byte)0);
        view.Write(9 + directoryBytes.Length, (byte)0);
        return file;
    }

    private static async Task ServePipeOnceAsync(
        NamedPipeServerStream pipe, byte[] payload)
    {
        await pipe.WaitForConnectionAsync();
        await pipe.WriteAsync(payload);
        await pipe.FlushAsync();
    }

    private static async Task WriteReceiptAsync(
        string path, Dictionary<string, object?> receipt)
    {
        var json = JsonSerializer.Serialize(receipt, ReceiptJsonOptions) + "\n";
        await File.WriteAllTextAsync(path, json, new UTF8Encoding(false));
    }

    private static string RequiredString(JsonElement element, string name)
    {
        var value = ReadString(element, name);
        Require(!string.IsNullOrEmpty(value), $"required_{name}_missing");
        return value;
    }

    private static string ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var property) &&
        property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;

    private static int ReadInt32(JsonElement element, string name) =>
        element.TryGetProperty(name, out var property) &&
        property.TryGetInt32(out var value)
            ? value
            : 0;

    private static bool ReadBoolean(JsonElement element, string name) =>
        element.TryGetProperty(name, out var property) &&
        property.ValueKind is JsonValueKind.True or JsonValueKind.False &&
        property.GetBoolean();

    private static string Md5Lower(string value)
    {
        var bytes = Encoding.ASCII.GetBytes(value);
        return Convert.ToHexString(MD5.HashData(bytes)).ToLowerInvariant();
    }

    private static string UtcNowText() =>
        DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",
            CultureInfo.InvariantCulture);

    private static void Require(bool condition, string reasonCode)
    {
        if (!condition)
        {
            throw new ControlledFailure(reasonCode);
        }
    }

    private sealed class ControlledFailure(string message) : Exception(message);
}
