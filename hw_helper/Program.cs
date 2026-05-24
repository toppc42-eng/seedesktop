using System.Management;
using System.Text.Json;
using LibreHardwareMonitor.Hardware;

namespace hw_helper;

internal static class Program
{
    private static int Main()
    {
        double? cpuTempC = null;
        ulong? fanRpm = null;
        string? cpuModel = null;
        double ramGb = 0;
        int ramSlotsUsed = 0;
        int? ramSlotsTotal = null;
        string ramSpeed = "Unknown";
        string ramType = "Unknown";
        string ramSlotsUsage = "Unknown";
        var diskInfo = new List<DiskInfoRow>();
        var logicalDiskSpecs = new List<LogicalDiskSpecRow>();
        var cpuCoresTemps = new List<CoreTempRow>();
        var fans = new List<FanRow>();

        // LibreHardwareMonitor first (per-core temps, real fan RPM).
        try
        {
            var (lhmTemp, lhmCores, lhmFans) = ReadLhmSensors();
            cpuTempC = lhmTemp;
            cpuCoresTemps = lhmCores;
            fans = lhmFans;
            if (fans.Count > 0)
                fanRpm = (ulong)fans.Max(f => f.RpmInt);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"hw_helper LHM: {ex.Message}");
        }

        // WMI fallback (covers cases where LHM driver can't load — e.g. no admin).
        if (cpuTempC is null)
        {
            try
            {
                cpuTempC = TryCpuTempMsaThermal() ?? TryCpuTempWin32Probe();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"hw_helper WMI (temp): {ex.Message}");
            }
        }
        if (fanRpm is null)
        {
            try
            {
                fanRpm = TryFanRpmWin32Fan();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"hw_helper WMI (fan): {ex.Message}");
            }
        }

        try
        {
            cpuModel = TryCpuModel();
            (ramGb, ramSlotsUsed, ramSlotsTotal, ramSpeed, ramType, ramSlotsUsage) = CollectRamInfo();
            diskInfo = CollectDiskInfo();
            logicalDiskSpecs = CollectLogicalDiskSpecs();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"hw_helper WMI (system info): {ex.Message}");
        }

        long? fanJson = null;
        if (fanRpm.HasValue)
        {
            var r = fanRpm.Value;
            fanJson = r > long.MaxValue ? long.MaxValue : (long)r;
        }

        var payload = new
        {
            cpu_temp_c = cpuTempC,
            fan_rpm = fanJson,
            cpu_model = cpuModel,
            ram_gb = Math.Round(ramGb, 2),
            ram_slots_used = ramSlotsUsed,
            ram_slots_total = ramSlotsTotal,
            ram_speed = ramSpeed,
            ram_type = ramType,
            ram_slots_usage = ramSlotsUsage,
            disk_info = diskInfo.Select(d => new { disk_model = d.Model, disk_type = d.Type }).ToList(),
            logical_disk_specs = logicalDiskSpecs.Select(d => new { id = d.Id, disk_model = d.DiskModel, disk_type = d.DiskType }).ToList(),
            cpu_cores_temp_c = cpuCoresTemps.Select(c => new { name = c.Name, temp_c = c.TempC }).ToList(),
            fans = fans.Select(f => new { name = f.Name, rpm = f.RpmInt }).ToList(),
        };

        Console.Out.WriteLine(JsonSerializer.Serialize(
            payload,
            new JsonSerializerOptions { WriteIndented = false }));
        return 0;
    }

    /// <summary>Visits every node in the LHM tree (LHM uses IVisitor).</summary>
    private sealed class UpdateVisitor : IVisitor
    {
        public void VisitComputer(IComputer computer) => computer.Traverse(this);
        public void VisitHardware(IHardware hardware)
        {
            hardware.Update();
            foreach (var sub in hardware.SubHardware)
                sub.Accept(this);
        }
        public void VisitSensor(ISensor sensor) { }
        public void VisitParameter(IParameter parameter) { }
    }

    /// <summary>
    /// Returns (packageTempC, per-core temps, fan rpms) from LibreHardwareMonitor.
    /// Requires admin privileges for CPU MSR access; returns nulls/empty otherwise.
    /// </summary>
    private static (double? PackageTempC, List<CoreTempRow> Cores, List<FanRow> Fans) ReadLhmSensors()
    {
        var cores = new List<CoreTempRow>();
        var fans = new List<FanRow>();
        double? packageTemp = null;

        var computer = new Computer
        {
            IsCpuEnabled = true,
            IsMotherboardEnabled = true,
            IsGpuEnabled = false,
            IsStorageEnabled = false,
            IsMemoryEnabled = false,
            IsNetworkEnabled = false,
            IsControllerEnabled = false,
            IsBatteryEnabled = false,
        };

        try
        {
            computer.Open();
            computer.Accept(new UpdateVisitor());

            foreach (var hardware in computer.Hardware)
            {
                CollectFromHardware(hardware, cores, fans, ref packageTemp);
                foreach (var sub in hardware.SubHardware)
                    CollectFromHardware(sub, cores, fans, ref packageTemp);
            }
        }
        finally
        {
            try { computer.Close(); } catch { /* ignore */ }
        }

        // If no explicit Package value found, use the hottest core as cpu_temp_c.
        if (packageTemp is null && cores.Count > 0)
            packageTemp = cores.Max(c => c.TempC);

        return (packageTemp, cores, fans);
    }

    private static void CollectFromHardware(
        IHardware hardware,
        List<CoreTempRow> cores,
        List<FanRow> fans,
        ref double? packageTemp)
    {
        foreach (var sensor in hardware.Sensors)
        {
            if (sensor.Value is not float v || !float.IsFinite(v))
                continue;

            switch (sensor.SensorType)
            {
                case SensorType.Temperature:
                    if (hardware.HardwareType != HardwareType.Cpu) break;
                    var name = sensor.Name ?? string.Empty;
                    // CPU Package overall reading.
                    if (name.Contains("Package", StringComparison.OrdinalIgnoreCase) ||
                        name.Equals("CPU Package", StringComparison.OrdinalIgnoreCase))
                    {
                        packageTemp = v;
                        break;
                    }
                    // Per-core readings (LHM names them "CPU Core #1", "Core #1", etc.).
                    if (name.Contains("Core", StringComparison.OrdinalIgnoreCase) &&
                        !name.Contains("Max", StringComparison.OrdinalIgnoreCase) &&
                        !name.Contains("Average", StringComparison.OrdinalIgnoreCase))
                    {
                        cores.Add(new CoreTempRow(name.Trim(), Math.Round(v, 1)));
                    }
                    break;
                case SensorType.Fan:
                    if (v > 0)
                        fans.Add(new FanRow(
                            sensor.Name?.Trim() ?? "Fan",
                            (long)Math.Round(v)));
                    break;
            }
        }
    }

    private static string? TryCpuModel()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\cimv2"),
                new ObjectQuery("SELECT Name FROM Win32_Processor"));
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    var name = o["Name"]?.ToString()?.Trim();
                    if (!string.IsNullOrEmpty(name))
                        return name;
                }
            }
        }
        catch
        {
            return null;
        }

        return null;
    }

    private static (double RamGb, int SlotsUsed, int? SlotsTotal, string RamSpeed, string RamType, string RamSlotsUsage)
        CollectRamInfo()
    {
        ulong totalBytes = 0;
        var slotsUsed = 0;
        uint maxSpeedMhz = 0;
        int? smbiosMemType = null;

        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\cimv2"),
                new ObjectQuery("SELECT Capacity, Speed, SMBIOSMemoryType FROM Win32_PhysicalMemory"));
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    if (o["Capacity"] is null)
                        continue;
                    totalBytes += Convert.ToUInt64(o["Capacity"]);
                    slotsUsed++;

                    try
                    {
                        if (o["Speed"] is not null)
                        {
                            var sp = Convert.ToUInt32(o["Speed"]);
                            if (sp > maxSpeedMhz)
                                maxSpeedMhz = sp;
                        }
                    }
                    catch
                    {
                        /* ignore */
                    }

                    if (smbiosMemType is null && o["SMBIOSMemoryType"] is not null)
                    {
                        try
                        {
                            smbiosMemType = Convert.ToInt32(o["SMBIOSMemoryType"]);
                        }
                        catch
                        {
                            /* ignore */
                        }
                    }
                }
            }
        }
        catch
        {
            /* leave zeros */
        }

        var ramGb = totalBytes / (1024.0 * 1024.0 * 1024.0);

        int? slotsTotal = null;
        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\cimv2"),
                new ObjectQuery("SELECT MemoryDevices FROM Win32_PhysicalMemoryArray"));
            var sum = 0;
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    if (o["MemoryDevices"] is null)
                        continue;
                    sum += Convert.ToInt32(o["MemoryDevices"]);
                }
            }

            if (sum > 0)
                slotsTotal = sum;
        }
        catch
        {
            /* optional */
        }

        var ramSpeed = maxSpeedMhz > 0 ? $"{maxSpeedMhz}MHz" : "Unknown";
        var ramType = SmbiosMemoryTypeToLabel(smbiosMemType);

        string ramSlotsUsage;
        if (slotsUsed <= 0 && slotsTotal is null or <= 0)
            ramSlotsUsage = "Unknown";
        else if (slotsTotal.HasValue && slotsTotal.Value > 0)
            ramSlotsUsage = $"{slotsUsed}/{slotsTotal.Value}";
        else
            ramSlotsUsage = slotsUsed > 0 ? $"{slotsUsed}/?" : "Unknown";

        return (ramGb, slotsUsed, slotsTotal, ramSpeed, ramType, ramSlotsUsage);
    }

    private static string SmbiosMemoryTypeToLabel(int? t)
    {
        if (t is null || t == 0)
            return "Unknown";
        return t.Value switch
        {
            20 => "DDR",
            21 => "DDR2",
            24 => "DDR3",
            26 => "DDR4",
            34 => "DDR5",
            _ => "Unknown",
        };
    }

    private static List<LogicalDiskSpecRow> CollectLogicalDiskSpecs()
    {
        var result = new List<LogicalDiskSpecRow>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\cimv2"),
                new ObjectQuery("SELECT DeviceID FROM Win32_LogicalDisk WHERE DriveType = 3"));
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    var id = o["DeviceID"]?.ToString()?.Trim() ?? "";
                    if (string.IsNullOrEmpty(id))
                        continue;
                    var (model, dtype) = TryPhysicalDiskForLogicalDisk(id);
                    result.Add(new LogicalDiskSpecRow(id, model, dtype));
                }
            }
        }
        catch
        {
            /* empty */
        }

        return result;
    }

    private static (string DiskModel, string DiskType) TryPhysicalDiskForLogicalDisk(string logicalDeviceId)
    {
        try
        {
            var esc = logicalDeviceId.Replace("'", "''");
            var q1 =
                $"ASSOCIATORS OF {{Win32_LogicalDisk.DeviceID='{esc}'}} WHERE AssocClass = Win32_LogicalDiskToPartition";
            using var s1 = new ManagementObjectSearcher(new ManagementScope(@"root\cimv2"), new ObjectQuery(q1));
            foreach (ManagementObject part in s1.Get())
            {
                using (part)
                {
                    var partId = part["DeviceID"]?.ToString();
                    if (string.IsNullOrEmpty(partId))
                        continue;
                    var esc2 = partId.Replace("'", "''");
                    var q2 =
                        $"ASSOCIATORS OF {{Win32_DiskPartition.DeviceID='{esc2}'}} WHERE AssocClass = Win32_DiskDriveToDiskPartition";
                    using var s2 = new ManagementObjectSearcher(new ManagementScope(@"root\cimv2"),
                        new ObjectQuery(q2));
                    foreach (ManagementObject drive in s2.Get())
                    {
                        using (drive)
                        {
                            var model = drive["Model"]?.ToString()?.Trim();
                            if (string.IsNullOrWhiteSpace(model))
                                model = "Unknown";
                            var dtype = InferDiskTypeFromDrive(drive);
                            return (model, dtype);
                        }
                    }
                }
            }
        }
        catch
        {
            /* fall through */
        }

        return ("Unknown", "Unknown");
    }

    private static string InferDiskTypeFromDrive(ManagementObject diskDrive)
    {
        try
        {
            var idxObj = diskDrive["Index"];
            if (idxObj is not null)
            {
                var index = Convert.ToUInt32(idxObj);
                using var s = new ManagementObjectSearcher(
                    new ManagementScope(@"root\Microsoft\Windows\Storage"),
                    new ObjectQuery("SELECT MediaType, DeviceId FROM MSFT_PhysicalDisk"));
                foreach (ManagementObject o in s.Get())
                {
                    using (o)
                    {
                        var devId = o["DeviceId"]?.ToString() ?? "";
                        if (devId.EndsWith(index.ToString(), StringComparison.Ordinal))
                        {
                            var mt = o["MediaType"] is null ? 0u : Convert.ToUInt32(o["MediaType"]);
                            return MediaTypeToDiskKind(mt);
                        }
                    }
                }
            }
        }
        catch
        {
            /* heuristic */
        }

        var m = diskDrive["Model"]?.ToString() ?? "";
        if (m.Contains("SSD", StringComparison.OrdinalIgnoreCase) ||
            m.Contains("NVMe", StringComparison.OrdinalIgnoreCase) ||
            m.Contains("NVME", StringComparison.OrdinalIgnoreCase))
            return "SSD";
        if (m.Contains("HDD", StringComparison.OrdinalIgnoreCase) ||
            m.Contains("ATA", StringComparison.OrdinalIgnoreCase) && !m.Contains("SSD", StringComparison.OrdinalIgnoreCase))
            return "HDD";
        return "Unknown";
    }

    private static List<DiskInfoRow> CollectDiskInfo()
    {
        var w32 = new List<(uint Index, string Model)>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\cimv2"),
                new ObjectQuery("SELECT Model, Index FROM Win32_DiskDrive"));
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    var idx = o["Index"] is null ? 0u : Convert.ToUInt32(o["Index"]);
                    var model = o["Model"]?.ToString()?.Trim() ?? "";
                    w32.Add((idx, model));
                }
            }
        }
        catch
        {
            /* empty */
        }

        w32.Sort((a, b) => a.Index.CompareTo(b.Index));

        var msft = new List<(string DeviceId, string Model, uint MediaType)>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\Microsoft\Windows\Storage"),
                new ObjectQuery("SELECT DeviceId, Model, MediaType FROM MSFT_PhysicalDisk"));
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    var id = o["DeviceId"]?.ToString() ?? "";
                    var model = o["Model"]?.ToString()?.Trim() ?? "";
                    var mt = o["MediaType"] is null ? 0u : Convert.ToUInt32(o["MediaType"]);
                    msft.Add((id, model, mt));
                }
            }
        }
        catch
        {
            /* empty — e.g. no Storage provider */
        }

        msft.Sort((a, b) => string.CompareOrdinal(a.DeviceId, b.DeviceId));

        var result = new List<DiskInfoRow>();
        var nW = w32.Count;
        var nM = msft.Count;

        for (var i = 0; i < nW; i++)
        {
            var model = w32[i].Model;
            if (string.IsNullOrWhiteSpace(model) && i < nM && !string.IsNullOrWhiteSpace(msft[i].Model))
                model = msft[i].Model;
            var type = i < nM ? MediaTypeToDiskKind(msft[i].MediaType) : "Unknown";
            if (!string.IsNullOrWhiteSpace(model) || type != "Unknown")
                result.Add(new DiskInfoRow(
                    string.IsNullOrWhiteSpace(model) ? "Unknown" : model,
                    type));
        }

        for (var i = nW; i < nM; i++)
        {
            var model = string.IsNullOrWhiteSpace(msft[i].Model) ? "Unknown" : msft[i].Model;
            result.Add(new DiskInfoRow(model, MediaTypeToDiskKind(msft[i].MediaType)));
        }

        return result;
    }

    private static string MediaTypeToDiskKind(uint mediaType) =>
        mediaType switch
        {
            3 => "HDD",
            4 => "SSD",
            _ => "Unknown",
        };

    /// <summary>root\WMI — tenths of Kelvin.</summary>
    private static double? TryCpuTempMsaThermal()
    {
        double? best = null;
        try
        {
            using var searcher = new ManagementObjectSearcher(
                @"root\WMI",
                "SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature");
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    var rawObj = o["CurrentTemperature"];
                    if (rawObj is null)
                        continue;
                    var raw = Convert.ToUInt32(rawObj);
                    var kelvinTenths = raw / 10.0;
                    var c = kelvinTenths - 273.15;
                    if (double.IsFinite(c) && c > -40.0 && c < 125.0)
                        best = best is null ? c : Math.Max(best.Value, c);
                }
            }
        }
        catch
        {
            return null;
        }

        return best;
    }

    /// <summary>root\cimv2 — CurrentReading is tenths of Kelvin per WMI schema.</summary>
    private static double? TryCpuTempWin32Probe()
    {
        double? best = null;
        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\cimv2"),
                new ObjectQuery("SELECT CurrentReading FROM Win32_TemperatureProbe"));
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    var rawObj = o["CurrentReading"];
                    if (rawObj is null)
                        continue;
                    var raw = Convert.ToInt32(rawObj);
                    var kelvinTenths = raw / 10.0;
                    var c = kelvinTenths - 273.15;
                    if (double.IsFinite(c) && c > -40.0 && c < 125.0)
                        best = best is null ? c : Math.Max(best.Value, c);
                }
            }
        }
        catch
        {
            return null;
        }

        return best;
    }

    private static ulong? TryFanRpmWin32Fan()
    {
        ulong? best = null;
        try
        {
            using var searcher = new ManagementObjectSearcher(
                new ManagementScope(@"root\cimv2"),
                new ObjectQuery("SELECT DesiredSpeed, VariableSpeed FROM Win32_Fan"));
            foreach (var o in searcher.Get())
            {
                using (o)
                {
                    var desired = o["DesiredSpeed"];
                    if (desired is not null)
                    {
                        var rpm = Convert.ToUInt64(desired);
                        if (rpm > 0)
                            best = best is null ? rpm : Math.Max(best.Value, rpm);
                        continue;
                    }

                    var variable = o["VariableSpeed"];
                    if (variable is not null && variable is not bool)
                    {
                        try
                        {
                            var v = Convert.ToUInt64(variable);
                            if (v > 0)
                                best = best is null ? v : Math.Max(best.Value, v);
                        }
                        catch
                        {
                            /* VariableSpeed is often boolean; ignore */
                        }
                    }
                }
            }
        }
        catch
        {
            return null;
        }

        return best;
    }

    private sealed record DiskInfoRow(string Model, string Type);

    private sealed record LogicalDiskSpecRow(string Id, string DiskModel, string DiskType);

    private sealed record CoreTempRow(string Name, double TempC);

    private sealed record FanRow(string Name, long RpmInt);
}
