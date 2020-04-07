"""
Authors:
    Dennis Schmitz, Sam Nooij, Florian Zwagemaker, Robert Verhagen,
    Jeroen Cremer, Thierry Janssens, Mark Kroon, Erwin van Wieringen,
    Annelies Kroneman, Harry Vennema, Marion Koopmans
Acknowledgements:
    Jeroen van Rooij, André Uitterlinden
Organization:
    Rijksinstituut voor Volksgezondheid en Milieu (RIVM)
    Dutch Public Health institute (https://www.rivm.nl/en)
Department:
    Virology - Emerging and Endemic Viruses (EEV)
    Virology - Viruses of the Vaccination Program (VVP)
    Bacteriology - Bacterial and Parasitic Diagnostics (BPD)
Date and license:
    19-12-2019, AGPL3 license
Description:
    Originally intended for the EAV internal control of the ENNGS ringtrail,
    later adapted for the nCoV outbreak. It's a WORK IN PROGRESS. It was
    initially intended for a coarse estimation of the BoC at different
    coverage thresholds.
Homepage containing documentation, examples and a changelog:
    https://github.com/DennisSchmitz/Jovian
Funding:
    This project/research has received funding from the European Union’s
    Horizon 2020 research and innovation programme under grant agreement
    No. 643476. and the Dutch working group on molecular diagnostics (WMDI).
"""


#@################################################################################
#@#### Import config file, sample_sheet and set output folder names          #####
#@################################################################################


shell.executable("/bin/bash")

# Load config files
configfile: "config/pipeline_parameters.yaml"
configfile: "config/variables.yaml"

# Load libraries
import pprint
import os
import yaml
yaml.warnings({'YAMLLoadWarning': False}) # Suppress yaml "unsafe" warnings.

# Import sample sheet
SAMPLES = {}
with open(config["sample_sheet"]) as sample_sheet_file:
    SAMPLES = yaml.load(sample_sheet_file) # SAMPLES is a dict with sample in the form sample > read number > file. E.g.: SAMPLES["sample_1"]["R1"] = "x_R1.gz"

# The reference file is given as a snakemake CLI argument from within the wrapper, so NOT via the pipeline_parameters.yaml
REFERENCE = config["reference"]
REFERENCE_BASENAME = os.path.splitext(os.path.basename(REFERENCE))[0]    # source: https://stackoverflow.com/questions/678236/how-to-get-the-filename-without-the-extension-from-a-path-in-python

# Set input directory, this is dependent on the Jovian output dir
INPUT_DIR_FILT_READS = config["reference_alignment"]["input_dir"]

# Set dir with conda-env files
CONDA_ENVS_DIR = "envs/"

# Set output base dir and sub-folder names, useful for easily changing the output locations during development.
OUTPUT_BASE_DIR = config["reference_alignment"]["output_dir"]
OUTPUT_DIR_REFERENCE = OUTPUT_BASE_DIR + "reference/"
OUTPUT_DIR_ALIGNMENT = OUTPUT_BASE_DIR + "alignment/"
OUTPUT_DIR_CONSENSUS_RAW = OUTPUT_BASE_DIR + "consensus_seqs/raw/"
OUTPUT_DIR_CONSENSUS_FILT = OUTPUT_BASE_DIR + "consensus_seqs/"
OUTPUT_DIR_BOC_ANALYSIS = OUTPUT_BASE_DIR + "BoC_analysis/"
OUTPUT_DIR_IGVjs = OUTPUT_BASE_DIR + "html/"

# gatk JvR upd
OUTPUT_DIR_GATK = OUTPUT_BASE_DIR + "gatk/"
OUTPUT_DIR_GATK_CONSENSUS_FILT = OUTPUT_DIR_GATK + "consensus/"
OUTPUT_DIR_GATK_BoC = OUTPUT_DIR_GATK + "BoC/"
OUTPUT_DIR_GATK_IGVjs = OUTPUT_DIR_GATK + "html/"
OUTPUT_GATK_IGVjs_HTML = OUTPUT_DIR_GATK + "igvjs.html"

# Set output dir of results
OUTPUT_DIR_RESULTS = OUTPUT_BASE_DIR + "results/"
OUTPUT_DIR_CONSENSUS_SEQS = OUTPUT_DIR_RESULTS + "consensus_seqs/"
OUTPUT_IGVjs_HTML = OUTPUT_DIR_RESULTS + "igvjs.html"
OUTPUT_MULTIQC_REPORT = OUTPUT_DIR_RESULTS + "multiqc.html"
OUTPUT_MULTIQC_REPORT_DATA = OUTPUT_DIR_RESULTS + "multiqc_data/"

# Set output dir of logfiles
OUTPUT_DIR_LOGS = config["reference_alignment"]["log_dir"] # NB the DRMAA logs will go the same dir as Jovian-core since this is set in the config.yaml file.
OUTPUT_DIR_BENCHMARKS = OUTPUT_DIR_LOGS + "benchmark/"


#@################################################################################
#@#### Specify Jovian's final output:                                        #####
#@################################################################################


localrules: 
    all,
    RA_index_reference,
    RA_determine_BoC_at_diff_cov_thresholds,
    RA_concat_BoC_metrics,
    RA_HTML_IGVJs_variable_parts,
    RA_HTML_IGVJs_generate_final,
    RA_gatk_read_group_preprocessing,
    RA_gatk_determine_BoC_at_diff_cov_thresholds,
    RA_gatk_concat_BoC_metrics,
    RA_gatk_HTML_IGVJs_variable_parts,
    RA_gatk_HTML_IGVJs_generate_final
    

rule all:
    input:
        expand("data/cleaned_fastq/{sample}_{read}.fq", sample = SAMPLES, read = [ 'pR1', 'pR2', 'unpaired' ]), # Extract unmapped & paired reads AND unpaired from HuGo alignment; i.e. cleaned fastqs #TODO omschrijven naar betere smk syntax
        expand("{out}{ref_basename}{extension}", out = OUTPUT_DIR_REFERENCE, ref_basename = REFERENCE_BASENAME, extension = [ '.fasta', '.fasta.1.bt2', '.dict', '.fasta.fai', '.fasta.sizes', '.windows', '_GC.bedgraph' ]), # Copy of the reference file (for standardization and easy logging), bowtie2-indices (I've only specified one, but the "2.bt2", "3.bt2", "4.bt2", "rev.1.bt2" and "rev.2.bt2" are implicitly generated) and the GC-content files.
        expand("{out}{sample}_sorted.{extension}", out = OUTPUT_DIR_ALIGNMENT, sample = SAMPLES, extension = [ 'bam', 'bam.bai' ]), # The reference alignment (bam format) files.
        expand("{out}{sample}_{extension}", out = OUTPUT_DIR_CONSENSUS_RAW, sample = SAMPLES, extension = [ 'calls.vcf.gz', 'raw_consensus.fa' ]), # A zipped vcf file contained SNPs versus the given reference and a RAW consensus sequence, see explanation below for the meaning of RAW.
        expand("{out}{sample}.bedgraph", out = OUTPUT_DIR_CONSENSUS_FILT, sample = SAMPLES), # Lists the coverage of the alignment against the reference in a bedgraph format, is used to determine the coverage mask files below.
        expand("{out}{sample}_{filt_character}-filt_cov_ge_{thresholds}.fa", out = OUTPUT_DIR_CONSENSUS_SEQS, sample = SAMPLES, filt_character = [ 'N', 'minus' ], thresholds = [ '1', '5', '10', '30', '100' ]), # Consensus sequences filtered for different coverage thresholds (1, 5, 10, 30 and 100). For each threshold two files are generated, one where failed positioned are replaced with a N nucleotide and the other where its replaced with a minus character (gap).
        expand("{out}{sample}_BoC{extension}", out = OUTPUT_DIR_BOC_ANALYSIS, sample = SAMPLES, extension = [ '_int.tsv', '_pct.tsv' ] ), # Output of the BoC analysis #TODO can probably removed after the concat rule is added.
        OUTPUT_DIR_RESULTS + "BoC_integer.tsv", # Integer BoC overview in .tsv format
        OUTPUT_DIR_RESULTS + "BoC_percentage.tsv", # Percentage BoC overview in .tsv format
        expand("{out}{ref_basename}_{extension}", out = OUTPUT_DIR_REFERENCE, ref_basename = REFERENCE_BASENAME , sample = SAMPLES, extension = [ 'ORF_AA.fa', 'ORF_NT.fa', 'annotation.gff', 'annotation.gff.gz', 'annotation.gff.gz.tbi' ]), # Prodigal ORF prediction output, required for the IGVjs visualisation
        OUTPUT_IGVjs_HTML, # IGVjs output html
        OUTPUT_MULTIQC_REPORT, # MultiQC report
        expand("{out}{sample}_{extension}", out = OUTPUT_DIR_GATK, sample = SAMPLES, extension = [ 'sorted_gatk.bam', 'sorted_gatk.bai' , 'gatk_MarkDup.metrics', 'gatk_MarkDup.bam', 'gatk_MarkDup.bai', 'gatk.vcf', 'gatk.vcf.gz', 'gatk.fa' ]), # GATK update JvR
        expand("{out}{sample}.bedgraph", out = OUTPUT_DIR_GATK, sample = SAMPLES), # JvR upd
        expand("{out}{sample}_{filt_character}-filt_cov_ge_{thresholds}.fa", out = OUTPUT_DIR_GATK_CONSENSUS_FILT, sample = SAMPLES, filt_character = [ 'N', 'minus' ], thresholds = [ '1', '5', '10', '30', '100' ]), # JvR upd
        OUTPUT_DIR_GATK_BoC + "results/" + "BoC_integer.tsv", # JvR upd
        OUTPUT_DIR_GATK_BoC + "results/" + "BoC_percentage.tsv", # JvR upd
        expand("{out}{sample}_BoC{extension}", out = OUTPUT_DIR_GATK_BoC, sample = SAMPLES, extension = [ '_int.tsv', '_pct.tsv' ] ), # JvR upd #TODO can probably removed after the concat rule is added.
        OUTPUT_GATK_IGVjs_HTML, # IGVjs output html


#@################################################################################
#@#### Reference alignment extension processes                               #####
#@################################################################################

#! rules via include statements are shared between core workflow and RA workflow
#>############################################################################
#>#### Data quality control and cleaning                                 #####
#>############################################################################

include: "rules/QC_raw.smk"
include: "rules/CleanData.smk"
include: 'rules/QC_clean.smk'

#>############################################################################
#>#### Removal of background host data                                   #####
#>############################################################################

include: "rules/BG_removal_1.smk"
include: "rules/BG_removal_2.smk"
include: "rules/BG_removal_3.smk"


##########! Also include fragment length *done* analysis and multiqc *done*
###? Tried adding the fraglength rule, but it break for samples without enough paired reads. Requires a touching of output files if the exit-code is non-zero. 
###TODO fixing above issue is something to do later, this also causes problems in the core workflow. So has some priority.

###########! nuttig om contig metrics rule ook toe te voegen?


#>############################################################################
#>#### Process the reference                                             #####
#>############################################################################
rule RA_index_reference:
    input:
        reference= REFERENCE
    output:
        reference_copy= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + ".fasta",
        reference_index= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + ".fasta.1.bt2", # I've only specified ".fasta.1.bt2", but the "2.bt2", "3.bt2", "4.bt2", "rev.1.bt2" and "rev.2.bt2" are implicitly generated. #TODO find a way to specify all output correctly (multiext snakemake syntax?)
        reference_gatk_dict= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + ".dict",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_index_reference.txt"
    threads: 4
    log:
        OUTPUT_DIR_LOGS + "RA_index_reference.log"
    shell: # The reference is copied to the hardcoded subdir to make it standardized and easily logged. Convert it to a two-line fasta for easier downstream processing.
        """
cat {input.reference} | seqtk seq - > {output.reference_copy}
bowtie2-build --threads {threads} {output.reference_copy} {output.reference_copy} >> {log} 2>&1
gatk CreateSequenceDictionary -R {output.reference_copy} >> {log} 2>&1
        """


##########################!
# Nuttig voor IGVjs vis. Gejat uit Jovian core met minor changes, kunnen we waarschijlijk efficienter doen. Bijvoorbeeld door gewoon een goed gecureerde ORF annotatie toe te voegen bij starten van analyse.
rule RA_reference_ORF_analysis:
    input:
        reference= rules.RA_index_reference.output.reference_copy
    output: 
        ORF_AA_fasta= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + "_ORF_AA.fa",
        ORF_NT_fasta= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + "_ORF_NT.fa",
        ORF_annotation_gff= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + "_annotation.gff",
        zipped_gff3= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + "_annotation.gff.gz",
        index_zipped_gff3= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + "_annotation.gff.gz.tbi",
    conda:
        CONDA_ENVS_DIR + "scaffold_analyses.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_reference_ORF_analysis.txt"
    log:
        OUTPUT_DIR_LOGS + "RA_reference_ORF_analysis.log"
    threads: 1
    params: #? Currently it's using the same prodigal settings as the main workflow, I see no problems with it since it's both foremost intended for viruses.
        procedure=config["ORF_prediction"]["procedure"],
        output_format=config["ORF_prediction"]["output_format"]
    shell:
        """
prodigal -q -i {input.reference} \
-a {output.ORF_AA_fasta} \
-d {output.ORF_NT_fasta} \
-o {output.ORF_annotation_gff} \
-p {params.procedure} \
-f {params.output_format} > {log} 2>&1
bgzip -c {output.ORF_annotation_gff} 2>> {log} 1> {output.zipped_gff3}
tabix -p gff {output.zipped_gff3} >> {log} 2>&1
        """


############################!
# Nuttig voor IGVjs vis. Gejat uit Jovian core met minor changes, kunnen we waarschijnlijk efficienter doen.
rule RA_determine_GC_content:
    input:
        fasta= rules.RA_index_reference.output.reference_copy,
    output:
        fasta_fai= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + ".fasta.fai",
        fasta_sizes= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + ".fasta.sizes",
        bed_windows= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + ".windows",
        GC_bed= OUTPUT_DIR_REFERENCE + REFERENCE_BASENAME + "_GC.bedgraph",
    conda:
        CONDA_ENVS_DIR + "scaffold_analyses.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_determine_GC_content.txt"
    log:
        OUTPUT_DIR_LOGS + "RA_determine_GC_content.log"
    threads: 1
    params:
        window_size="50"
    shell:
        """
samtools faidx -o {output.fasta_fai} {input.fasta} > {log} 2>&1
cut -f 1,2 {output.fasta_fai} 2> {log} 1> {output.fasta_sizes}
bedtools makewindows \
-g {output.fasta_sizes} \
-w {params.window_size} 2>> {log} 1> {output.bed_windows}
bedtools nuc \
-fi {input.fasta} \
-bed {output.bed_windows} 2>> {log} |\
cut -f 1-3,5 2>> {log} 1> {output.GC_bed}
        """


#>############################################################################
#>#### Align to ref, call SNPs, generate new consensus                   #####
#>############################################################################
rule RA_align_to_reference:
    input:
        pR1= rules.HuGo_removal_pt2_extract_paired_unmapped_reads.output.fastq_R1,
        pR2= rules.HuGo_removal_pt2_extract_paired_unmapped_reads.output.fastq_R2,
        unpaired= rules.HuGo_removal_pt3_extract_unpaired_unmapped_reads.output,
        reference= rules.RA_index_reference.output.reference_copy
    output:
        sorted_bam= OUTPUT_DIR_ALIGNMENT + "{sample}_sorted.bam",
        sorted_bam_index= OUTPUT_DIR_ALIGNMENT + "{sample}_sorted.bam.bai",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_align_to_reference_{sample}.txt"
    threads: config["threads"]["RA_align_to_reference"]
    log:
        OUTPUT_DIR_LOGS + "RA_align_to_reference_{sample}.log"
    params:
        alignment_type="--local",
    shell:
        """
bowtie2 --time --threads {threads} {params.alignment_type} \
-x {input.reference} \
-1 {input.pR1} \
-2 {input.pR2} \
-U {input.unpaired} 2> {log} |\
samtools view -@ {threads} -uS - 2>> {log} |\
samtools sort -@ {threads} - -o {output.sorted_bam} >> {log} 2>&1
samtools index -@ {threads} {output.sorted_bam} >> {log} 2>&1
        """


##################################################################################################################################
# BEGIN JvR update
##################################################################################################################################


#TODO jovian verion includeren in de SAM/BAM header velden?
#TODO uitzoeken of niet gewoon de .bam.bai van samtools gebruikt kan worden? Dan kan '-CREATE_INDEX TRUE' verwijderd worden.
rule RA_gatk_read_group_preprocessing:
    input:
        bam= rules.RA_align_to_reference.output.sorted_bam,
    output:
        preprocessed_bam= OUTPUT_DIR_GATK + "{sample}_sorted_gatk.bam",
        preprocessed_bam_bai= OUTPUT_DIR_GATK + "{sample}_sorted_gatk.bai"
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_read_group_preprocessing_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_read_group_preprocessing_{sample}.log"
    params:
    shell: # Based on this post (https://gatkforums.broadinstitute.org/gatk/discussion/24304/the-importance-of-sorting-markduplicate-output-files) we can apparently skip the gatk SortSam. #TODO still discuss with JvR and test this. For now, I'll hold this as true and NOT include gatk SortSam.
        """
gatk AddOrReplaceReadGroups -I {input.bam} \
-CREATE_INDEX TRUE \
-RGID Jovian \
-RGCN RIVM \
-RGLB RIVM \
-RGPL ILL \
-RGPU Jovian \
-RGSM {wildcards.sample} \
-O {output.preprocessed_bam} >> {log} 2>&1
        """


rule RA_gatk_MarkDuplicates:
    input:
        bam= rules.RA_gatk_read_group_preprocessing.output.preprocessed_bam,
        reference= rules.RA_index_reference.output.reference_copy
    output:
        metrics= OUTPUT_DIR_GATK + "{sample}_gatk_MarkDup.metrics",
        bam_markdup= OUTPUT_DIR_GATK + "{sample}_gatk_MarkDup.bam",
        bam_bai_markdup= OUTPUT_DIR_GATK + "{sample}_gatk_MarkDup.bai"
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_MarkDuplicates_{sample}.txt"
    threads: 6 # it uses only one thread, however, this is done to not exceed the max RAM of the nodes (i.e. 26 jobs with 30GB RAM on one node)
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_MarkDuplicates_{sample}.log"
    params:
    shell:
        """
gatk MarkDuplicates --java-options "-Xmx30G" \
-CREATE_INDEX TRUE \
-I {input.bam} \
-R {input.reference} \
-M {output.metrics} \
-O {output.bam_markdup} >> {log} 2>&1
        """


rule RA_gatk_haplotypecaller_and_raw_consensus:
    input:
        bam= rules.RA_gatk_MarkDuplicates.output.bam_markdup,
        reference= rules.RA_index_reference.output.reference_copy
    output:
        vcf= OUTPUT_DIR_GATK + "{sample}_gatk.vcf",
        gzipped_vcf= OUTPUT_DIR_GATK + "{sample}_gatk.vcf.gz",
        raw_consensus_fasta= OUTPUT_DIR_GATK + "{sample}_gatk.fa",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_haplotypecaller_and_raw_consensus_{sample}.txt"
    threads: 6 # it uses only one thread, however, this is done to not exceed the max RAM of the nodes (i.e. 26 jobs with 30GB RAM on one node)
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_haplotypecaller_and_raw_consensus_{sample}.log"
    params: # Set field below to `--disable-read-filter NotDuplicateReadFilter` to NOT remove duplicate-marked reads. Set this field to ``, i.e. empty, to REMOVE duplicate-makred reads. #TODO testen of dit idd goed werkt met een leeg veld.
        remove_duplicate_reads= "" #TODO hier nog een if statement for schrijven in pure python i.c.m. een checker bovenaan deze snakemake om de juiste params te krijgen.
    shell:
        """
gatk HaplotypeCaller --java-options "-Xmx30G" \
-R {input.reference} \
-I {input.bam} \
--sample-ploidy 1 \
{params.remove_duplicate_reads} \
-O {output.vcf} >> {log} 2>&1
bcftools view -O z -o {output.gzipped_vcf} {output.vcf} >> {log} 2>&1
tabix {output.gzipped_vcf} >> {log} 2>&1
bcftools consensus -f {input.reference} {output.gzipped_vcf} | seqtk seq - > {output.raw_consensus_fasta} 2>> {log}
        """


#TODO, dirty copy, just a proof-of-principle test
###! lijkt te werken, 1e ruwe test
#TODO kijken of dit multithreaded kan worden.
rule RA_gatk_extract_clean_consensus:
    input:
        bam= rules.RA_gatk_MarkDuplicates.output.bam_markdup,
        reference= rules.RA_index_reference.output.reference_copy,
        raw_consensus= rules.RA_gatk_haplotypecaller_and_raw_consensus.output.raw_consensus_fasta, # Only needed for when there are no positions in the bed with a coverage of 0; in that case the RAW fasta is actually suitable for downstream processes and it is simply copied.
    output:
        bedgraph= OUTPUT_DIR_GATK + "{sample}.bedgraph",
        filt_consensus_N_filt_ge_1= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_N-filt_cov_ge_1.fa",
        filt_consensus_N_filt_ge_5= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_N-filt_cov_ge_5.fa",
        filt_consensus_N_filt_ge_10= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_N-filt_cov_ge_10.fa",
        filt_consensus_N_filt_ge_30= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_N-filt_cov_ge_30.fa",
        filt_consensus_N_filt_ge_100= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_N-filt_cov_ge_100.fa",
        filt_consensus_minus_filt_ge_1= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_minus-filt_cov_ge_1.fa",
        filt_consensus_minus_filt_ge_5= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_minus-filt_cov_ge_5.fa",
        filt_consensus_minus_filt_ge_10= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_minus-filt_cov_ge_10.fa",
        filt_consensus_minus_filt_ge_30= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_minus-filt_cov_ge_30.fa",
        filt_consensus_minus_filt_ge_100= OUTPUT_DIR_GATK_CONSENSUS_FILT + "{sample}_minus-filt_cov_ge_100.fa",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_extract_clean_consensus_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_extract_clean_consensus_{sample}.log"
    params:
        output_data_folder= OUTPUT_DIR_GATK,
        output_results_folder= OUTPUT_DIR_GATK_CONSENSUS_FILT
    shell:
        """
bash bin/scripts/RA_consensus_at_diff_coverages.sh {wildcards.sample} {input.bam} {input.reference} {input.raw_consensus} \
{params.output_data_folder} {params.output_results_folder} {log} >> {log} 2>&1
        """



#TODO, dirty copy, just a proof-of-principle test
###! identieke output als de andere workflow, maar dat is logisch, zelfde dingen worden uitgevoerd (dit zit erin om, afhankelijk van uitkomst deze test, dit later verder uit te breiden)#TODO make a python script or bash function/include to do this more efficiently, currently it's hacky, but it works
rule RA_gatk_determine_BoC_at_diff_cov_thresholds:
    input:
        bedgraph= rules.RA_gatk_extract_clean_consensus.output.bedgraph,
        reference= rules.RA_index_reference.output.reference_copy,
    output:
        percentage_BoC_tsv= OUTPUT_DIR_GATK_BoC + "{sample}_BoC_pct.tsv",
        integer_BoC_tsv= OUTPUT_DIR_GATK_BoC + "{sample}_BoC_int.tsv",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_determine_BoC_at_diff_cov_thresholds_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_determine_BoC_at_diff_cov_thresholds_{sample}.log"
    params:
    shell:
        """
bash bin/scripts/RA_BoC_analysis.sh {wildcards.sample} {input.bedgraph} {input.reference} \
{output.percentage_BoC_tsv} {output.integer_BoC_tsv} >> {log} 2>&1
        """



#TODO, dirty copy, just a proof-of-principle test
###! identieke output als de andere workflow, maar dat is logisch, zelfde dingen worden uitgevoerd (dit zit erin om, afhankelijk van uitkomst deze test, dit later verder uit te breiden)
rule RA_gatk_concat_BoC_metrics:
    input:
        BoC_int_tsv= expand("{out}{sample}_BoC_int.tsv", out = OUTPUT_DIR_GATK_BoC, sample = SAMPLES),
        BoC_pct_tsv= expand("{out}{sample}_BoC_pct.tsv", out = OUTPUT_DIR_GATK_BoC, sample = SAMPLES),
    output:
        combined_BoC_int_tsv= OUTPUT_DIR_GATK_BoC + "results/" + "BoC_integer.tsv",
        combined_BoC_pct_tsv= OUTPUT_DIR_GATK_BoC + "results/" + "BoC_percentage.tsv",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_concat_BoC_metrics.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_concat_BoC_metrics.log"
    params:
    shell:
        """
echo -e "Sample_name\tTotal_ref_size\tBoC_at_coverage_threshold_1\tBoC_at_coverage_threshold_5\tBoC_at_coverage_threshold_10\tBoC_at_coverage_threshold_30\tBoC_at_coverage_threshold_100" > {output.combined_BoC_int_tsv}
cat {input.BoC_int_tsv} >> {output.combined_BoC_int_tsv}

echo -e "Sample_name\tTotal_ref_size\tBoC_at_coverage_threshold_1\tBoC_at_coverage_threshold_5\tBoC_at_coverage_threshold_10\tBoC_at_coverage_threshold_30\tBoC_at_coverage_threshold_100" > {output.combined_BoC_pct_tsv}
cat {input.BoC_pct_tsv} >> {output.combined_BoC_pct_tsv}
        """


#TODO, dirty copy, just a proof-of-principle test
###! lijkt het goed weer te geven, je ziet dat MarkDup reads worden gemerged van multiple records naar 'e'en.
rule RA_gatk_HTML_IGVJs_variable_parts:
    input:
        fasta= rules.RA_index_reference.output.reference_copy,
        ref_GC_bedgraph= rules.RA_determine_GC_content.output.GC_bed, 
        ref_zipped_ORF_gff= rules.RA_reference_ORF_analysis.output.zipped_gff3, 
        basepath_zipped_SNP_vcf= rules.RA_gatk_haplotypecaller_and_raw_consensus.output.gzipped_vcf,
        basepath_sorted_bam= rules.RA_gatk_MarkDuplicates.output.bam_markdup,
    output:
        tab_output= OUTPUT_DIR_GATK_IGVjs + "2_tab_{sample}",
        div_output= OUTPUT_DIR_GATK_IGVjs + "4_html_divs_{sample}",
        js_flex_output= OUTPUT_DIR_GATK_IGVjs + "6_js_flex_{sample}",
    conda:
        CONDA_ENVS_DIR + "data_wrangling.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_HTML_IGVJs_variable_parts_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_HTML_IGVJs_variable_parts_{sample}.log"
    params:
    shell:
        """
bash bin/html/RA_igvjs_write_tabs.sh {wildcards.sample} {output.tab_output}

bash bin/html/RA_igvjs_write_divs.sh {wildcards.sample} {output.div_output}

bash bin/html/RA_igvjs_write_flex_js_middle.sh {wildcards.sample} {output.js_flex_output} \
{input.fasta} {input.ref_GC_bedgraph} {input.ref_zipped_ORF_gff} \
{input.basepath_zipped_SNP_vcf} {input.basepath_sorted_bam}
        """


#TODO, dirty copy, just a proof-of-principle test
###! lijkt het goed weer te geven, je ziet dat MarkDup reads worden gemerged van multiple records naar 'e'en.
###! wel een snelle hack moeten inbouwen voor de bam index file van MarkDup
rule RA_gatk_HTML_IGVJs_generate_final:
    input:
        expand("{out}{chunk_name}_{sample}", out = OUTPUT_DIR_GATK_IGVjs, chunk_name = [ '2_tab', '4_html_divs', '6_js_flex' ], sample = SAMPLES)
    output:
        OUTPUT_GATK_IGVjs_HTML
    conda:
        CONDA_ENVS_DIR + "data_wrangling.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_gatk_HTML_IGVJs_generate_final.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_gatk_HTML_IGVJs_generate_final.log"
    params:
        tab_basename= OUTPUT_DIR_GATK_IGVjs + "2_tab_",
        div_basename= OUTPUT_DIR_GATK_IGVjs + "4_html_divs_",
        js_flex_output= OUTPUT_DIR_GATK_IGVjs + "6_js_flex_",
    shell:
        """
cat files/html_chunks/1_header.html > {output}
cat {params.tab_basename}* >> {output}
cat files/html_chunks/3_tab_explanation_RA.html >> {output}
cat {params.div_basename}* >> {output}
cat files/html_chunks/5_js_begin.html >> {output}
cat {params.js_flex_output}* >> {output}
cat files/html_chunks/7_js_end.html >> {output}
sed -i 's/gatk_MarkDup.bam.bai/gatk_MarkDup.bai/g' {output}
        """ # Die sed op het laatst is een snelle hack om te werken met de output van gatk, die spuugt geen .bam.bai uit maar .bai.


##################################################################################################################################
# END JvR update
##################################################################################################################################


rule RA_extract_raw_consensus:
    input:
        bam= rules.RA_align_to_reference.output.sorted_bam,
        reference= rules.RA_index_reference.output.reference_copy,
    output:
        gzipped_vcf= OUTPUT_DIR_CONSENSUS_RAW + "{sample}_calls.vcf.gz",
        raw_consensus_fasta= OUTPUT_DIR_CONSENSUS_RAW + "{sample}_raw_consensus.fa",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_extract_raw_consensus_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_extract_raw_consensus_{sample}.log"
    params:
    shell: # Source: https://github.com/samtools/bcftools/wiki/HOWTOs#consensus-calling
        """
samtools mpileup -uf {input.reference} {input.bam} 2>> {log} |\
bcftools call --ploidy 1 -mv -O z -o {output.gzipped_vcf} >> {log} 2>&1
tabix {output.gzipped_vcf} >> {log} 2>&1
cat {input.reference} 2>> {log} |\
bcftools consensus {output.gzipped_vcf} | seqtk seq - > {output.raw_consensus_fasta} 2>> {log}
        """


#TODO kijken of dit multithreaded kan worden.
rule RA_extract_clean_consensus:
    input:
        bam= rules.RA_align_to_reference.output.sorted_bam,
        reference= rules.RA_index_reference.output.reference_copy,
        raw_consensus= rules.RA_extract_raw_consensus.output.raw_consensus_fasta, # Only needed for when there are no positions in the bed with a coverage of 0; in that case the RAW fasta is actually suitable for downstream processes and it is simply copied.
    output:
        bedgraph= OUTPUT_DIR_CONSENSUS_FILT + "{sample}.bedgraph",
        filt_consensus_N_filt_ge_1= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_N-filt_cov_ge_1.fa",
        filt_consensus_N_filt_ge_5= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_N-filt_cov_ge_5.fa",
        filt_consensus_N_filt_ge_10= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_N-filt_cov_ge_10.fa",
        filt_consensus_N_filt_ge_30= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_N-filt_cov_ge_30.fa",
        filt_consensus_N_filt_ge_100= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_N-filt_cov_ge_100.fa",
        filt_consensus_minus_filt_ge_1= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_minus-filt_cov_ge_1.fa",
        filt_consensus_minus_filt_ge_5= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_minus-filt_cov_ge_5.fa",
        filt_consensus_minus_filt_ge_10= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_minus-filt_cov_ge_10.fa",
        filt_consensus_minus_filt_ge_30= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_minus-filt_cov_ge_30.fa",
        filt_consensus_minus_filt_ge_100= OUTPUT_DIR_CONSENSUS_SEQS + "{sample}_minus-filt_cov_ge_100.fa",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_extract_clean_consensus_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_extract_clean_consensus_{sample}.log"
    params:
        output_data_folder= OUTPUT_DIR_CONSENSUS_FILT,
        output_results_folder= OUTPUT_DIR_CONSENSUS_SEQS
    shell:
        """
bash bin/scripts/RA_consensus_at_diff_coverages.sh {wildcards.sample} {input.bam} {input.reference} {input.raw_consensus} \
{params.output_data_folder} {params.output_results_folder} {log} >> {log} 2>&1
        """


#TODO make a python script or bash function/include to do this more efficiently, currently it's hacky, but it works
rule RA_determine_BoC_at_diff_cov_thresholds:
    input:
        bedgraph= rules.RA_extract_clean_consensus.output.bedgraph,
        reference= rules.RA_index_reference.output.reference_copy,
    output:
        percentage_BoC_tsv= OUTPUT_DIR_BOC_ANALYSIS + "{sample}_BoC_pct.tsv",
        integer_BoC_tsv= OUTPUT_DIR_BOC_ANALYSIS + "{sample}_BoC_int.tsv",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "determine_BoC_at_diff_cov_thresholds_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_determine_BoC_at_diff_cov_thresholds_{sample}.log"
    params:
    shell:
        """
bash bin/scripts/RA_BoC_analysis.sh {wildcards.sample} {input.bedgraph} {input.reference} \
{output.percentage_BoC_tsv} {output.integer_BoC_tsv} >> {log} 2>&1
        """


rule RA_concat_BoC_metrics:
    input:
        BoC_int_tsv= expand("{out}{sample}_BoC_int.tsv", out = OUTPUT_DIR_BOC_ANALYSIS, sample = SAMPLES),
        BoC_pct_tsv= expand("{out}{sample}_BoC_pct.tsv", out = OUTPUT_DIR_BOC_ANALYSIS, sample = SAMPLES),
    output:
        combined_BoC_int_tsv= OUTPUT_DIR_RESULTS + "BoC_integer.tsv",
        combined_BoC_pct_tsv= OUTPUT_DIR_RESULTS + "BoC_percentage.tsv",
    conda:
        CONDA_ENVS_DIR + "RA_ref_alignment.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "concat_BoC_metrics.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_concat_BoC_metrics.log"
    params:
    shell:
        """
echo -e "Sample_name\tTotal_ref_size\tBoC_at_coverage_threshold_1\tBoC_at_coverage_threshold_5\tBoC_at_coverage_threshold_10\tBoC_at_coverage_threshold_30\tBoC_at_coverage_threshold_100" > {output.combined_BoC_int_tsv}
cat {input.BoC_int_tsv} >> {output.combined_BoC_int_tsv}

echo -e "Sample_name\tTotal_ref_size\tBoC_at_coverage_threshold_1\tBoC_at_coverage_threshold_5\tBoC_at_coverage_threshold_10\tBoC_at_coverage_threshold_30\tBoC_at_coverage_threshold_100" > {output.combined_BoC_pct_tsv}
cat {input.BoC_pct_tsv} >> {output.combined_BoC_pct_tsv}
        """


##########################!
# Gejat uit Jovian core met minor changes, kunnen we waarschijlijk efficienter doen.
# TODO the report is still a bit dirty since we include two bowtie2 metric files:
#### TODO one for the hugo removal
#### TODO another for the ref alignment
#### TODOD hence the '-d' flag in the multiqc command based on https://multiqc.info/docs/#directory-names
rule RA_MultiQC_report:
    input:
        expand("data/FastQC_pretrim/{sample}_{read}_fastqc.zip", sample = SAMPLES, read = "R1 R2".split()), # TODO dit moet nog verbetert worden qua smk syntax
        expand("data/FastQC_posttrim/{sample}_{read}_fastqc.zip", sample = SAMPLES, read = "pR1 pR2 uR1 uR2".split()), # TODO dit moet nog verbetert worden qua smk syntax
        expand("logs/Clean_the_data_{sample}.log", sample = SAMPLES), # TODO dit moet nog verbetert worden qua smk syntax
        expand("logs/HuGo_removal_pt1_alignment_{sample}.log", sample = SAMPLES), # TODO dit moet nog verbetert worden qua smk syntax
        expand("{out}RA_align_to_reference_{sample}.log", out = OUTPUT_DIR_LOGS, sample = SAMPLES), # TODO dit moet nog verbetert worden qua smk syntax
    output:
        OUTPUT_MULTIQC_REPORT,
        expand("{out}multiqc_{program}.txt", out = OUTPUT_MULTIQC_REPORT_DATA, program = ['trimmomatic','bowtie2','fastqc']),
    conda:
        CONDA_ENVS_DIR + "MultiQC_report.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_MultiQC_report.txt"
    threads: 1
    params:
        config_file="files/multiqc_config.yaml",
        output_dir= OUTPUT_DIR_RESULTS,
    log:
        OUTPUT_DIR_LOGS + "RA_MultiQC_report.log"
    shell:
        """
multiqc -d --force --config {params.config_file} \
-o {params.output_dir} -n multiqc.html {input} > {log} 2>&1
        """


#@################################################################################
#@#### Make IGVjs html                                                       #####
#@################################################################################
#############! All code below here should be integrated with Jovian core workflow


rule RA_HTML_IGVJs_variable_parts:
    input:
        fasta= rules.RA_index_reference.output.reference_copy,
        ref_GC_bedgraph= rules.RA_determine_GC_content.output.GC_bed,
        ref_zipped_ORF_gff= rules.RA_reference_ORF_analysis.output.zipped_gff3,
        basepath_zipped_SNP_vcf= rules.RA_extract_raw_consensus.output.gzipped_vcf,
        basepath_sorted_bam= rules.RA_align_to_reference.output.sorted_bam,
    output:
        tab_output= OUTPUT_DIR_IGVjs + "2_tab_{sample}",
        div_output= OUTPUT_DIR_IGVjs + "4_html_divs_{sample}",
        js_flex_output= OUTPUT_DIR_IGVjs + "6_js_flex_{sample}",
    conda:
        CONDA_ENVS_DIR + "data_wrangling.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_HTML_IGVJs_variable_parts_{sample}.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_HTML_IGVJs_variable_parts_{sample}.log"
    params:
    shell:
        """
bash bin/html/RA_igvjs_write_tabs.sh {wildcards.sample} {output.tab_output}

bash bin/html/RA_igvjs_write_divs.sh {wildcards.sample} {output.div_output}

bash bin/html/RA_igvjs_write_flex_js_middle.sh {wildcards.sample} {output.js_flex_output} \
{input.fasta} {input.ref_GC_bedgraph} {input.ref_zipped_ORF_gff} \
{input.basepath_zipped_SNP_vcf} {input.basepath_sorted_bam}
        """


rule RA_HTML_IGVJs_generate_final:
    input:
        expand("{out}{chunk_name}_{sample}", out = OUTPUT_DIR_IGVjs, chunk_name = [ '2_tab', '4_html_divs', '6_js_flex' ], sample = SAMPLES)
    output:
        OUTPUT_IGVjs_HTML
    conda:
        CONDA_ENVS_DIR + "data_wrangling.yaml"
    benchmark:
        OUTPUT_DIR_BENCHMARKS + "RA_HTML_IGVJs_generate_final.txt"
    threads: 1
    log:
        OUTPUT_DIR_LOGS + "RA_HTML_IGVJs_generate_final.log"
    params:
        tab_basename= OUTPUT_DIR_IGVjs + "2_tab_",
        div_basename= OUTPUT_DIR_IGVjs + "4_html_divs_",
        js_flex_output= OUTPUT_DIR_IGVjs + "6_js_flex_",
    shell:
        """
cat files/html_chunks/1_header.html > {output}
cat {params.tab_basename}* >> {output}
cat files/html_chunks/3_tab_explanation_RA.html >> {output}
cat {params.div_basename}* >> {output}
cat files/html_chunks/5_js_begin.html >> {output}
cat {params.js_flex_output}* >> {output}
cat files/html_chunks/7_js_end.html >> {output}
        """


#@################################################################################
#@#### These are the conditional cleanup rules                               #####
#@################################################################################


onsuccess:
    shell("""
        echo -e "\nCleaning up..."
        
        echo -e "\tRemoving temporary files..."
        if [ "{config[remove_temp]}" != "0" ]; then
            rm -rf {OUTPUT_DIR_IGVjs}   # Remove intermediate IGVjs html chunks.
        else
            echo -e "\t\tYou chose not to remove temp files, skipping..."
        fi

        echo -e "\tCreating symlinks for the interactive genome viewer..."
        bash bin/scripts/set_symlink.sh

        echo -e "\tGenerating Snakemake report..."
        snakemake -s bin/Ref_alignment.smk --unlock --config config --config reference={REFERENCE}
        snakemake -s bin/Ref_alignment.smk --report {OUTPUT_DIR_RESULTS}snakemake_report.html --config config --config reference={REFERENCE}

        echo -e "Finished"
    """)
