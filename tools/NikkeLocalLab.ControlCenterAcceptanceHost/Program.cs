using Microsoft.Extensions.DependencyInjection;
using NikkeLocalLab.Admin.Api;
using NikkeLocalLab.Persistence.PostgreSql;

var connectionString = Environment.GetEnvironmentVariable("NIKKE_LAB_DB");
var bootstrapPath = Environment.GetEnvironmentVariable("NLL_CONTROL_CENTER_BOOTSTRAP_PATH");
var portText = Environment.GetEnvironmentVariable("NLL_CONTROL_CENTER_PORT");
if (string.IsNullOrWhiteSpace(connectionString) ||
    string.IsNullOrWhiteSpace(bootstrapPath) ||
    !int.TryParse(portText, out var port) || port is < 1024 or > 65535)
{
  Console.Error.WriteLine("control_center_acceptance_host_configuration_invalid");
  return 1;
}

try
{
  await using var runtime = await PostgreSqlProfileManagementRuntime.CreateAsync(connectionString);
  await using var app = AdminApiHost.Build(
      [],
      new AdminApiHostOptions
      {
        Port = port,
        BootstrapCodeSink = code => File.WriteAllText(bootstrapPath, code),
        ConfigureServices = services => services.AddSingleton(runtime.Service)
      });
  await app.RunAsync();
  return 0;
}
catch (Exception exception)
{
  Console.Error.WriteLine(
      $"control_center_acceptance_host_failed:{exception.GetType().Name}:{exception.Message}");
  return 1;
}
