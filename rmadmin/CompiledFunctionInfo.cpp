extern "C" {
# include <caml/memory.h>
# include <caml/alloc.h>
# include <caml/custom.h>
# undef alloc
# undef flush
}
#include "CompiledFunctionInfo.h"
#include "confValue.h"
#include "EventTime.h"
#include "RamenType.h"

// Does not alloc on OCaml heap
CompiledFunctionInfo::CompiledFunctionInfo(value v_)
{
  assert(Is_block(v_));
  assert(Wosize_val(v_) == 8);
  value tmp_ = Field(v_, 1);  // the (optional) retention
  retention = nullptr;
  if (Is_block(tmp_)) {
    tmp_ = Field(tmp_, 0);
    assert(Tag_val(tmp_) == Double_array_tag);
    retention =
      new conf::Retention(Double_field(tmp_, 0), Double_field(tmp_, 1));
  }
  name = String_val(Field(v_, 0));
  is_lazy = Bool_val(Field(v_, 2));
  doc = String_val(Field(v_, 3));
  // field 5 is the operation, which is too hard to parse. Hopefully we have those:
  outType = std::make_shared<RamenType const>(Field(v_, 5));
  for (tmp_ = Field(v_, 6); Is_block(tmp_); tmp_ = Field(tmp_, 1)) {
    factors.append(QString(String_val(Field(tmp_, 0))));
  }
  eventTime = std::make_shared<EventTime const>(*outType);
  signature = String_val(Field(v_, 7));
}

CompiledFunctionInfo::CompiledFunctionInfo(CompiledFunctionInfo &&other) :
  name(std::move(other.name)),
  is_lazy(other.is_lazy),
  doc(std::move(other.doc)),
  outType(other.outType),
  factors(std::move(other.factors)),
  signature(std::move(other.signature))
{
  retention = other.retention;
  other.retention = nullptr;
}

CompiledFunctionInfo::CompiledFunctionInfo(CompiledFunctionInfo const &other) :
  name(other.name),
  is_lazy(other.is_lazy),
  doc(other.doc),
  outType(other.outType),
  factors(other.factors),
  signature(other.signature)
{
  if (other.retention) {
    retention = new conf::Retention(*other.retention);
  } else {
    retention = nullptr;
  }
}

CompiledFunctionInfo::~CompiledFunctionInfo()
{
  if (retention) delete retention;
}
