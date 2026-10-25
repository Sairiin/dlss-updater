# Lettura/scrittura delle impostazioni globali del driver NVIDIA tramite NVAPI
# (nvapi64.dll, installata con il driver). Codici di funzioni e impostazioni presi
# dal repository ufficiale github.com/NVIDIA/nvapi (nvapi_interface.h, NvApiDriverSettings.h).
# (c) Sairiin - tutti i diritti riservati.

if (-not ('NvDrs' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NvDrs
{
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr QueryInterface(uint id);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D0();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DOutH(out IntPtr h);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DH(IntPtr h);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DHOutP(IntPtr h, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DGet(IntPtr h, IntPtr p, uint id, IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DSet(IntPtr h, IntPtr p, IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] delegate int DFile(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] string f);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DDel(IntPtr h, IntPtr p, uint id);

    static T F<T>(uint id) where T : class
    {
        IntPtr p = QueryInterface(id);
        if (p == IntPtr.Zero) throw new Exception("Funzione NVAPI 0x" + id.ToString("X8") + " non disponibile");
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }

    // NVDRS_SETTING_V1 con #pragma pack(4): 4 + 4096 + 5*4 + 4100 + 4100 = 12320 byte.
    const int SettingSize = 12320;
    const uint SettingVer = (uint)SettingSize | (1u << 16);
    const int OffId = 4100, OffType = 4104, OffLocation = 4108, OffIsPredef = 4112, OffCurrent = 8220;
    public const int NotFound = -160;

    static void Check(int r, string what) { if (r != 0) throw new Exception(what + " ha restituito l'errore NVAPI " + r); }

    static IntPtr Open(out IntPtr profile)
    {
        Check(F<D0>(0x0150e828)(), "NvAPI_Initialize");
        IntPtr s; Check(F<DOutH>(0x0694d52e)(out s), "CreateSession");
        Check(F<DH>(0x375dbd6b)(s), "LoadSettings");
        Check(F<DHOutP>(0x617bff9f)(s, out profile), "GetCurrentGlobalProfile");
        return s;
    }
    static void Close(IntPtr s) { F<DH>(0xdad9cff8)(s); }

    // Valore DWORD attuale nel profilo globale; null se l'impostazione non e' stata toccata (valore predefinito del driver).
    public static uint?[] Read(uint[] ids)
    {
        IntPtr prof; IntPtr s = Open(out prof);
        IntPtr buf = Marshal.AllocHGlobal(SettingSize);
        try
        {
            uint?[] res = new uint?[ids.Length];
            for (int i = 0; i < ids.Length; i++)
            {
                for (int b = 0; b < SettingSize; b++) Marshal.WriteByte(buf, b, 0);
                Marshal.WriteInt32(buf, 0, (int)SettingVer);
                int r = F<DGet>(0x73bf8338)(s, prof, ids[i], buf);
                if (r == NotFound) { res[i] = null; continue; }
                Check(r, "GetSetting 0x" + ids[i].ToString("X8"));
                res[i] = (uint)Marshal.ReadInt32(buf, OffCurrent);
            }
            return res;
        }
        finally { Marshal.FreeHGlobal(buf); Close(s); }
    }

    public static void Write(uint[] ids, uint[] values)
    {
        IntPtr prof; IntPtr s = Open(out prof);
        IntPtr buf = Marshal.AllocHGlobal(SettingSize);
        try
        {
            for (int i = 0; i < ids.Length; i++)
            {
                for (int b = 0; b < SettingSize; b++) Marshal.WriteByte(buf, b, 0);
                Marshal.WriteInt32(buf, 0, (int)SettingVer);
                Marshal.WriteInt32(buf, OffId, (int)ids[i]);
                Marshal.WriteInt32(buf, OffType, 0);            // NVDRS_DWORD_TYPE
                Marshal.WriteInt32(buf, OffCurrent, (int)values[i]);
                Check(F<DSet>(0x577dd202)(s, prof, buf), "SetSetting 0x" + ids[i].ToString("X8"));
            }
            Check(F<DH>(0xfcbc7e14)(s), "SaveSettings");
        }
        finally { Marshal.FreeHGlobal(buf); Close(s); }
    }

    // --- Profili dei singoli giochi ---
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] delegate int DFindApp(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] string app, out IntPtr p, IntPtr appInfo);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] delegate int DFindProf(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] string name, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DCreateProf(IntPtr h, IntPtr info, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DCreateApp(IntPtr h, IntPtr p, IntPtr appInfo);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DHP(IntPtr h, IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DProfInfo(IntPtr h, IntPtr p, IntPtr info);

    // NVDRS_APPLICATION_V4: 4+4 + 4x4096 + 4 + 4096 = 20492 byte; NVDRS_PROFILE_V1: 4+4096+4+4+4+4 = 4116 byte.
    const int AppSize = 20492, ProfSize = 4116;
    const uint AppVer = (uint)AppSize | (4u << 16), ProfVer = (uint)ProfSize | (1u << 16);

    static IntPtr Zeroed(int size, uint ver)
    {
        IntPtr b = Marshal.AllocHGlobal(size);
        for (int i = 0; i < size; i++) Marshal.WriteByte(b, i, 0);
        Marshal.WriteInt32(b, 0, (int)ver);
        return b;
    }
    static void WriteW(IntPtr b, int off, string s)
    {
        char[] c = s.ToCharArray();
        for (int i = 0; i < c.Length && i < 2047; i++) Marshal.WriteInt16(b, off + 2 * i, (short)c[i]);
    }
    static string ReadW(IntPtr b, int off) { return Marshal.PtrToStringUni(new IntPtr(b.ToInt64() + off)); }

    static IntPtr OpenLoaded()
    {
        Check(F<D0>(0x0150e828)(), "NvAPI_Initialize");
        IntPtr s; Check(F<DOutH>(0x0694d52e)(out s), "CreateSession");
        Check(F<DH>(0x375dbd6b)(s), "LoadSettings");
        return s;
    }

    // Profilo che contiene uno degli eseguibili (o quello col nome dato). Zero se non esiste.
    static IntPtr FindProfile(IntPtr s, string[] exes, string profileName, out string foundName)
    {
        foundName = null;
        IntPtr app = Zeroed(AppSize, AppVer), info = Zeroed(ProfSize, ProfVer);
        try
        {
            IntPtr p = IntPtr.Zero;
            foreach (string e in exes)
                if (F<DFindApp>(0xeee566b2)(s, e, out p, app) == 0 && p != IntPtr.Zero) break; else p = IntPtr.Zero;
            if (p == IntPtr.Zero && !String.IsNullOrEmpty(profileName) && F<DFindProf>(0x7e4a9a0b)(s, profileName, out p) != 0) p = IntPtr.Zero;
            if (p != IntPtr.Zero && F<DProfInfo>(0x61cd6fd6)(s, p, info) == 0) foundName = ReadW(info, 4);
            return p;
        }
        finally { Marshal.FreeHGlobal(app); Marshal.FreeHGlobal(info); }
    }

    // Valori delle impostazioni nel profilo del gioco (null = non impostate in quel profilo).
    public static uint?[] ReadApp(string[] exes, string profileName, uint[] ids, out string profile)
    {
        IntPtr s = OpenLoaded();
        IntPtr buf = Marshal.AllocHGlobal(SettingSize);
        try
        {
            uint?[] res = new uint?[ids.Length];
            IntPtr p = FindProfile(s, exes, profileName, out profile);
            if (p == IntPtr.Zero) return res;
            for (int i = 0; i < ids.Length; i++)
            {
                for (int b = 0; b < SettingSize; b++) Marshal.WriteByte(buf, b, 0);
                Marshal.WriteInt32(buf, 0, (int)SettingVer);
                if (F<DGet>(0x73bf8338)(s, p, ids[i], buf) != 0) continue;
                // Conta solo se il valore e' scritto in questo profilo (non ereditato dal globale).
                if (Marshal.ReadInt32(buf, OffLocation) == 0) res[i] = (uint)Marshal.ReadInt32(buf, OffCurrent);
            }
            return res;
        }
        finally { Marshal.FreeHGlobal(buf); Close(s); }
    }

    // Scrive le impostazioni nel profilo del gioco; se non esiste lo crea con quegli eseguibili.
    // Restituisce il nome del profilo e se e' stato creato adesso.
    public static string WriteApp(string[] exes, string newProfileName, uint[] ids, uint[] values, out bool created)
    {
        created = false;
        IntPtr s = OpenLoaded();
        IntPtr buf = Marshal.AllocHGlobal(SettingSize);
        try
        {
            string name;
            IntPtr p = FindProfile(s, exes, newProfileName, out name);
            if (p == IntPtr.Zero)
            {
                IntPtr info = Zeroed(ProfSize, ProfVer);
                try { WriteW(info, 4, newProfileName); Check(F<DCreateProf>(0xcc176068)(s, info, out p), "CreateProfile"); }
                finally { Marshal.FreeHGlobal(info); }
                foreach (string e in exes)
                {
                    IntPtr app = Zeroed(AppSize, AppVer);
                    try { WriteW(app, 8, e); WriteW(app, 4104, newProfileName); Check(F<DCreateApp>(0x4347a9de)(s, p, app), "CreateApplication " + e); }
                    finally { Marshal.FreeHGlobal(app); }
                }
                created = true; name = newProfileName;
            }
            for (int i = 0; i < ids.Length; i++)
            {
                for (int b = 0; b < SettingSize; b++) Marshal.WriteByte(buf, b, 0);
                Marshal.WriteInt32(buf, 0, (int)SettingVer);
                Marshal.WriteInt32(buf, OffId, (int)ids[i]);
                Marshal.WriteInt32(buf, OffType, 0);
                Marshal.WriteInt32(buf, OffCurrent, (int)values[i]);
                Check(F<DSet>(0x577dd202)(s, p, buf), "SetSetting 0x" + ids[i].ToString("X8"));
            }
            Check(F<DH>(0xfcbc7e14)(s), "SaveSettings");
            return name;
        }
        finally { Marshal.FreeHGlobal(buf); Close(s); }
    }

    // Toglie le impostazioni dal profilo del gioco; se il profilo l'aveva creato il tool lo cancella.
    public static void ClearApp(string[] exes, string profileName, uint[] ids, bool deleteProfile)
    {
        IntPtr s = OpenLoaded();
        try
        {
            string name;
            IntPtr p = FindProfile(s, exes, profileName, out name);
            if (p == IntPtr.Zero) return;
            if (deleteProfile && name == profileName) Check(F<DHP>(0x17093206)(s, p), "DeleteProfile");
            else foreach (uint id in ids) F<DDel>(0xe4a26362)(s, p, id);   // "non trovata" va bene
            Check(F<DH>(0xfcbc7e14)(s), "SaveSettings");
        }
        finally { Close(s); }
    }

    // Copia completa di tutti i profili del driver, e suo ripristino.
    public static void Export(string file)
    {
        IntPtr prof; IntPtr s = Open(out prof);
        try { Check(F<DFile>(0x2be25df8)(s, file), "SaveSettingsToFile"); } finally { Close(s); }
    }
    public static void Import(string file)
    {
        Check(F<D0>(0x0150e828)(), "NvAPI_Initialize");
        IntPtr s; Check(F<DOutH>(0x0694d52e)(out s), "CreateSession");
        try
        {
            Check(F<DFile>(0xd3ede889)(s, file), "LoadSettingsFromFile");
            Check(F<DH>(0xfcbc7e14)(s), "SaveSettings");
        }
        finally { Close(s); }
    }
}
'@
}

# Impostazioni globali gestite, con i codici ufficiali di NvApiDriverSettings.h.
$NvIds = [ordered]@{
    VSync      = [uint32]0x00A879CF
    LowLatency = [uint32]0x007BA09E   # PRERENDERLIMIT: 1 = "Modalita' bassa latenza: Attiva"
    Power      = [uint32]0x1057EB71   # PREFERRED_PSTATE
    MaxFps     = [uint32]0x10835002   # FRL_FPS
    GSync      = [uint32]0x1194F158   # VRR_MODE
    ShaderMB   = [uint32]0x00AC8497   # PS_SHADERDISKCACHE_MAX_SIZE (MB)
}

# Override DLSS (come "Override DLSS" dell'app NVIDIA): attiva + modello "piu' recente".
$NvLatestPreset = [uint32]0x00FFFFFF
$NvOverride = [ordered]@{
    SrOverride = [uint32]0x10E41E01   # NGX_DLSS_SR_OVERRIDE
    SrPreset   = [uint32]0x10E41DF3   # NGX_DLSS_SR_OVERRIDE_RENDER_PRESET_SELECTION
    RrOverride = [uint32]0x10E41E02   # NGX_DLSS_RR_OVERRIDE
    RrPreset   = [uint32]0x10E41DF7   # NGX_DLSS_RR_OVERRIDE_RENDER_PRESET_SELECTION
}
$NvOverrideValues = [uint32[]]@(1, $NvLatestPreset, 1, $NvLatestPreset)

function Get-NvGlobalSettings {
    $ids = [uint32[]]@($NvIds.Values)
    $vals = [NvDrs]::Read($ids)
    $r = [ordered]@{}
    $i = 0
    foreach ($k in $NvIds.Keys) { $r[$k] = $vals[$i]; $i++ }
    return $r
}
