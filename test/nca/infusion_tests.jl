using PuMaS.NCA, Test, CSV
using PuMaS
using Random

file = PuMaS.example_nmtran_data("nca_test_data/patient_data_test_sk")
df = CSV.read(file)
timeu, concu, amtu = u"hr", u"mg/L", u"mg"
data = @test_nowarn parse_ncadata(df, id=:ID, time=:Time, conc=:Prefilter_Conc, warn=false, formulation=:Mode, route=(iv = Inf,), amt=:Amount, duration=:Infusion_Time, timeu=timeu, concu=concu, amtu=amtu)
@test data[1].dose === NCADose(0.0timeu, 750amtu, 0.25timeu, NCA.IVInfusion)
@test NCA.mrt(data; auctype=:last)[:mrt] == NCA.aumclast(data)[:aumclast]./NCA.auclast(data)[:auclast] .- 0.25timeu/2
@test NCA.mrt(data; auctype=:inf)[:mrt] == NCA.aumc(data)[:aumc]./NCA.auc(data)[:auc] .- 0.25timeu/2
