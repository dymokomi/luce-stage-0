; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/sum_types.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/sum_types.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.zero.State = private constant [2 x { i8, i8, [6 x i8], i64, i64 }] [{ i8, i8, [6 x i8], i64, i64 } { i8 2, i8 0, [6 x i8] zeroinitializer, i64 0, i64 0 }, { i8, i8, [6 x i8], i64, i64 } zeroinitializer]
@luce.text.0 = private unnamed_addr constant [40 x i8] c"function ended without returning a value"
@luce.text.1 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.2 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.3 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.4 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.text.5 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.6 = private unnamed_addr constant [5 x i8] c"score"
@luce.text.7 = private unnamed_addr constant [60 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/sum_types.luc"
@luce.origins.0 = private constant [15 x { i32, i32 }] [{ i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 8, i32 13 }, { i32, i32 } { i32 8, i32 13 }, { i32, i32 } { i32 8, i32 13 }, { i32, i32 } { i32 8, i32 13 }, { i32, i32 } { i32 8, i32 13 }, { i32, i32 } { i32 10, i32 13 }, { i32, i32 } { i32 10, i32 13 }, { i32, i32 } { i32 10, i32 13 }]
@luce.text.8 = private unnamed_addr constant [4 x i8] c"main"
@luce.origins.1 = private constant [16 x { i32, i32 }] [{ i32, i32 } { i32 13, i32 5 }, { i32, i32 } { i32 13, i32 5 }, { i32, i32 } { i32 13, i32 5 }, { i32, i32 } { i32 13, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }]
@luce.functions = private constant [2 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 5, ptr @luce.text.7, i64 60, ptr @luce.origins.0, i64 15 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.8, i64 4, ptr @luce.text.7, i64 60, ptr @luce.origins.1, i64 16 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.score(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, ptr align 8 readonly nonnull noundef %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i64, align 8
  store ptr %3, ptr %6, align 8
  store ptr @luce.zero.State, ptr %7, align 8
  store i64 0, ptr %8, align 8
  br label %9

9:
  %10 = load ptr, ptr %6, align 8
  store ptr %10, ptr %7, align 8
  %11 = load ptr, ptr %7, align 8
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i64 0
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %12, i32 0, i32 3
  %14 = load i64, ptr %13, align 8
  %15 = icmp eq i64 %14, 0
  br i1 %15, label %16, label %20

16:
  store i64 0, ptr %4, align 8
  ret i32 0

17:
  %18 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 40 }, 0
  %19 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 40 }, 1
  call void @luce_rt_raise(ptr %1, i32 5, ptr %18, i64 %19)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 14)
  ret i32 1

20:
  %21 = load ptr, ptr %7, align 8
  %22 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i64 1
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 3
  %24 = load i64, ptr %23, align 8
  store i64 %24, ptr %8, align 8
  %25 = load i64, ptr %8, align 8
  store i64 %25, ptr %4, align 8
  ret i32 0
}

define internal i32 @luce.1.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %7 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 0
  store i8 5, ptr %9, align 1
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  store i64 2, ptr %10, align 8
  %11 = ptrtoint ptr null to i64
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  store i64 %11, ptr %12, align 8
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 5, ptr %13, align 1
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 2, ptr %14, align 8
  %15 = ptrtoint ptr null to i64
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %15, ptr %16, align 8
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 4, ptr %17, align 1
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  store i8 -1, ptr %18, align 1
  %19 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 0 }, 0
  %20 = ptrtoint ptr %19 to i64
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %20, ptr %21, align 8
  %22 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 0 }, 1
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 %22, ptr %23, align 8
  %24 = alloca { i8, i8, [6 x i8], i64, i64 },i64 2, align 8
  %25 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i64 0
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 0
  store i8 2, ptr %26, align 1
  %27 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 4
  store i64 0, ptr %27, align 8
  %28 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i64 1
  %29 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 0
  store i8 2, ptr %29, align 1
  %30 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 4
  store i64 0, ptr %30, align 8
  %31 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %32 = sub nsw i64 %2, 1
  %33 = alloca i64, align 8
  %34 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %35 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i32 0, i32 0
  store i8 2, ptr %35, align 1
  %36 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i32 0, i32 4
  store i64 0, ptr %36, align 8
  %37 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %38 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %39 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %40

40:
  %41 = load i64, ptr %5, align 8
  %42 = trunc i64 %41 to i32
  %43 = lshr i64 %41, 32
  %44 = trunc i64 %43 to i32
  %45 = icmp eq i32 %42, -1
  br i1 %45, label %46, label %49, !prof !0

46:
  %47 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 0
  %48 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %47, i64 %48)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

49:
  %50 = getelementptr inbounds i8, ptr %1, i64 96
  %51 = load ptr, ptr %50, align 8!alias.scope !1, !noalias !2
  %52 = zext i32 %42 to i64
  %53 = mul nsw i64 %52, 112
  %54 = getelementptr inbounds i8, ptr %51, i64 %53
  %55 = getelementptr inbounds i8, ptr %54, i64 96
  %56 = load i32, ptr %55, align 4, !alias.scope !1, !noalias !2
  %57 = icmp ne i32 %56, %44
  br i1 %57, label %58, label %61, !prof !0

58:
  %59 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %60 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %59, i64 %60)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

61:
  %62 = and i32 %56, 1
  %63 = icmp ne i32 %62, 0
  br i1 %63, label %64, label %67, !prof !0

64:
  %65 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %66 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %65, i64 %66)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

67:
  %68 = getelementptr inbounds i8, ptr %54, i64 16
  %69 = load i64, ptr %68, align 8!alias.scope !1, !noalias !2
  %70 = load ptr, ptr %54, align 8, !alias.scope !1, !noalias !2
  %71 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 3
  store i64 1, ptr %71, align 8
  %72 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 3
  store i64 %69, ptr %72, align 8
  %73 = call i32 @luce_rt_struct_make(ptr %1, ptr %24, i64 2, ptr %31)
  %74 = icmp ne i32 %73, 0
  br i1 %74, label %75, label %76, !prof !0

75:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 2)
  ret i32 1

76:
  %77 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 3
  %78 = load i64, ptr %77, align 8
  %79 = inttoptr i64 %78 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %31, i64 24, i1 false)
  %80 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %81 = load i64, ptr %80, align 8
  %82 = inttoptr i64 %81 to ptr
  %83 = icmp slt i64 %32, 1
  br i1 %83, label %84, label %87, !prof !0

84:
  %85 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 19 }, 0
  %86 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %85, i64 %86)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 5)
  ret i32 1

87:
  %88 = call i32 @luce.0.score(ptr %0, ptr %1, i64 %32, ptr %82, ptr %33)
  %89 = icmp ne i32 %88, 0
  br i1 %89, label %90, label %91, !prof !0

90:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 5)
  ret i32 1

91:
  %92 = load i64, ptr %33, align 8
  %93 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i32 0, i32 3
  store i64 %92, ptr %93, align 8
  %94 = call i32 @luce_rt_str(ptr %1, ptr %34, ptr %37)
  %95 = icmp ne i32 %94, 0
  br i1 %95, label %96, label %97, !prof !0

96:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 6)
  ret i32 1

97:
  %98 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 3
  %99 = load i64, ptr %98, align 8
  %100 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 1
  %101 = load i8, ptr %100, align 1
  %102 = icmp eq i8 %101, -1
  %103 = inttoptr i64 %99 to ptr
  %104 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 2
  %105 = select i1 %102, ptr %103, ptr %104
  %106 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 4
  %107 = load i64, ptr %106, align 8
  %108 = zext i8 %101 to i64
  %109 = select i1 %102, i64 %107, i64 %108
  %110 = insertvalue { ptr, i64 } poison, ptr %105, 0
  %111 = insertvalue { ptr, i64 } %110, i64 %109, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %37, i64 24, i1 false)
  %112 = extractvalue { ptr, i64 } %111, 0
  %113 = extractvalue { ptr, i64 } %111, 1
  %114 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %115 = load ptr, ptr %114, align 8
  %116 = icmp eq ptr %115, null
  br i1 %116, label %117, label %120, !prof !0

117:
  %118 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %119 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %118, i64 %119)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

120:
  %121 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %122 = load ptr, ptr %121, align 8
  %123 = call i32 %115(ptr %122, ptr %112, i64 %113)
  %124 = icmp eq i32 %123, -1
  br i1 %124, label %125, label %126, !prof !0

125:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

126:
  %127 = icmp ne i32 %123, 0
  %128 = icmp ne i32 %123, 1
  %129 = and i1 %127, %128
  br i1 %129, label %130, label %133, !prof !0

130:
  %131 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %132 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %131, i64 %132)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

133:
  %134 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %135 = load i64, ptr %134, align 8
  %136 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  %137 = load i8, ptr %136, align 1
  %138 = icmp eq i8 %137, -1
  %139 = inttoptr i64 %135 to ptr
  %140 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 2
  %141 = select i1 %138, ptr %139, ptr %140
  %142 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  %143 = load i64, ptr %142, align 8
  %144 = zext i8 %137 to i64
  %145 = select i1 %138, i64 %143, i64 %144
  %146 = insertvalue { ptr, i64 } poison, ptr %141, 0
  %147 = insertvalue { ptr, i64 } %146, i64 %145, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %8, ptr %38)
  %148 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 3
  %149 = load i64, ptr %148, align 8
  %150 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 1
  %151 = load i8, ptr %150, align 1
  %152 = icmp eq i8 %151, -1
  %153 = inttoptr i64 %149 to ptr
  %154 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 2
  %155 = select i1 %152, ptr %153, ptr %154
  %156 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 4
  %157 = load i64, ptr %156, align 8
  %158 = zext i8 %151 to i64
  %159 = select i1 %152, i64 %157, i64 %158
  %160 = insertvalue { ptr, i64 } poison, ptr %155, 0
  %161 = insertvalue { ptr, i64 } %160, i64 %159, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %38, i64 24, i1 false)
  %162 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %163 = load i64, ptr %162, align 8
  %164 = inttoptr i64 %163 to ptr
  call void @luce_rt_drop_storage(ptr %1, ptr %7, ptr %39)
  %165 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 3
  %166 = load i64, ptr %165, align 8
  %167 = inttoptr i64 %166 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %39, i64 24, i1 false)
  ret i32 0
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_struct_make(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull noundef %1, i64 %2, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %3) #1

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #2

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #4

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #1

define i32 @luce_main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0) {
1:
  %2 = alloca i64, align 8
  %3 = alloca i32, align 8
  store i64 256, ptr %2, align 8
  %4 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %5 = load ptr, ptr %4, align 8
  %6 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 14
  %7 = load ptr, ptr %6, align 8
  %8 = icmp eq ptr %7, null
  br i1 %8, label %11, label %9

9:
  %10 = call i64 %7(ptr %5)
  store i64 %10, ptr %2, align 8
  br label %11

11:
  %12 = load i64, ptr %2, align 8
  %13 = call ptr @luce_rt_open(ptr @luce.functions, i64 2)
  %14 = icmp eq ptr %13, null
  br i1 %14, label %15, label %16, !prof !0

15:
  ret i32 2

16:
  %17 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 28
  %18 = load ptr, ptr %17, align 8
  %19 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 54
  %20 = load ptr, ptr %19, align 8
  %21 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 55
  %22 = load ptr, ptr %21, align 8
  %23 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 56
  %24 = load ptr, ptr %23, align 8
  %25 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 57
  %26 = load ptr, ptr %25, align 8
  %27 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 58
  %28 = load ptr, ptr %27, align 8
  %29 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 29
  %30 = load ptr, ptr %29, align 8
  %31 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 30
  %32 = load ptr, ptr %31, align 8
  %33 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 31
  %34 = load ptr, ptr %33, align 8
  %35 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 32
  %36 = load ptr, ptr %35, align 8
  call void @luce_rt_files_install(ptr %13, ptr %5, ptr %18, ptr %20, ptr %22, ptr %24, ptr %26, ptr %28, ptr %30, ptr %32, ptr %34, ptr %36)
  %37 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 48
  %38 = load ptr, ptr %37, align 8
  %39 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 49
  %40 = load ptr, ptr %39, align 8
  %41 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 50
  %42 = load ptr, ptr %41, align 8
  %43 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 51
  %44 = load ptr, ptr %43, align 8
  %45 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 52
  %46 = load ptr, ptr %45, align 8
  call void @luce_rt_sockets_install(ptr %13, ptr %5, ptr %38, ptr %40, ptr %42, ptr %44, ptr %46)
  %47 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 40
  %48 = load ptr, ptr %47, align 8
  %49 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 41
  %50 = load ptr, ptr %49, align 8
  %51 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 42
  %52 = load ptr, ptr %51, align 8
  %53 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 43
  %54 = load ptr, ptr %53, align 8
  %55 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 44
  %56 = load ptr, ptr %55, align 8
  %57 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 45
  %58 = load ptr, ptr %57, align 8
  %59 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 46
  %60 = load ptr, ptr %59, align 8
  %61 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 47
  %62 = load ptr, ptr %61, align 8
  call void @luce_rt_graphics_install(ptr %13, ptr %5, ptr %48, ptr %50, ptr %52, ptr %54, ptr %56, ptr %58, ptr %60, ptr %62)
  %63 = icmp slt i64 %12, 1
  br i1 %63, label %64, label %65, !prof !0

64:
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.4, i64 19)
  store i32 1, ptr %3, align 8
  br label %73

65:
  %66 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %67 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 4
  %68 = load ptr, ptr %67, align 8
  %69 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 5
  %70 = load ptr, ptr %69, align 8
  %71 = call i32 @luce_rt_args_list(ptr %13, ptr %5, ptr %68, ptr %70, ptr %66)
  %72 = icmp ne i32 %71, 0
  br i1 %72, label %77, label %78, !prof !0

73:
  %74 = load i32, ptr %3, align 8
  %75 = icmp eq i32 %74, 1
  %76 = icmp eq i32 %74, 2
  br i1 %75, label %83, label %86, !prof !0

77:
  store i32 1, ptr %3, align 8
  br label %73

78:
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %66, i32 0, i32 3
  %80 = load i64, ptr %79, align 8
  %81 = call i32 @luce.1.main(ptr %0, ptr %13, i64 %12, i64 %80)
  store i32 %81, ptr %3, align 8
  %82 = call i32 @luce_rt_release(ptr %13, ptr %66)
  br label %73

83:
  %84 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 2
  %85 = load ptr, ptr %84, align 8
  call void @luce_rt_report(ptr %13, ptr %5, ptr %85)
  br label %86

86:
  br i1 %76, label %87, label %90, !prof !0

87:
  %88 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 15
  %89 = load ptr, ptr %88, align 8
  call void @luce_rt_report_error(ptr %13, ptr %5, ptr %89)
  br label %90

90:
  %91 = call i32 @luce_rt_status(ptr %13, i32 %74)
  %92 = icmp eq i32 %91, 2
  %93 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 3
  %94 = load ptr, ptr %93, align 8
  %95 = icmp eq ptr %94, null
  %96 = or i1 %95, %92
  br i1 %96, label %97, label %98

97:
  call void @luce_rt_close(ptr %13)
  ret i32 %91

98:
  %99 = call i64 @luce_rt_leaked(ptr %13)
  call void %94(ptr %5, i64 %99)
  br label %97
}

; Function Attrs: nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite)
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #6

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #7

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #6

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #8

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #8

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #9

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #9

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #10

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #10

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #8

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #3 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind cold willreturn memory(argmem: write) }
attributes #5 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #6 = { nounwind willreturn memory(argmem: readwrite) }
attributes #7 = { nounwind willreturn memory(readwrite) }
attributes #8 = { nounwind memory(readwrite) }
attributes #9 = { cold }
attributes #10 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!3}
!2 = !{!4}
!3 = !{!"luce.rows", !5}
!4 = !{!"luce.elements", !5}
!5 = !{!"luce.alias"}
